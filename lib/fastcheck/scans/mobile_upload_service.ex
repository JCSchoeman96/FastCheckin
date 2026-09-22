defmodule FastCheck.Scans.MobileUploadService do
  @moduledoc """
  Orchestrates authoritative mobile scan uploads backed by Redis hot state and
  Oban durability handoff.
  """

  require Logger

  import Ecto.Query, warn: false

  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.Scans.Result
  alias FastCheck.Scans.Validator

  @type api_result :: %{idempotency_key: String.t(), status: String.t(), message: String.t()}
  @type service_error :: %{status: atom(), code: String.t(), message: String.t()}

  @spec upload_batch(integer(), list()) :: {:ok, [api_result()]} | {:error, service_error()}
  def upload_batch(event_id, scans) when is_integer(event_id) and is_list(scans) do
    upload_authoritative(event_id, scans)
  end

  defp upload_authoritative(event_id, scans) do
    config = ingestion_config()
    store = config.store

    with {:ok, processed} <- process_authoritative_batch(event_id, scans, config),
         {:ok, to_enqueue} <- enqueue_candidates(processed),
         :ok <-
           enqueue_all_required_jobs(
             event_id,
             to_enqueue,
             config.chunk_size,
             config.force_enqueue_failure
           ),
         :ok <- promote_results(store, to_enqueue, config.live_namespace) do
      {:ok,
       Enum.map(processed, fn
         {:api_result, result} ->
           result

         {:result, %Result{delivery_state: :final_acknowledged} = result} ->
           Result.to_duplicate_api_result(result)

         {:result, %Result{} = result} ->
           Result.to_api_result(result)
       end)}
    else
      {:error, %{status: _status} = error} ->
        {:error, error}

      {:error, reason} ->
        Logger.error("Authoritative mobile upload failed: #{inspect(reason)}")

        {:error,
         %{
           status: :service_unavailable,
           code: "scan_ingestion_failed",
           message: "Unable to queue scan durability handoff"
         }}
    end
  end

  defp process_authoritative_batch(event_id, scans, config) do
    store = config.store

    Enum.reduce_while(scans, {:ok, []}, fn scan, {:ok, acc} ->
      case Validator.validate(event_id, scan) do
        {:ok, command} ->
          case store.process_scan(command, config.live_namespace) do
            {:ok, result} ->
              {:cont, {:ok, acc ++ [{:result, result}]}}

            {:error, reason} ->
              {:halt, {:error, hot_state_error(reason)}}
          end

        {:error, reason} ->
          {:cont, {:ok, acc ++ [{:api_result, invalid_scan_api_result(scan, reason)}]}}
      end
    end)
  end

  defp enqueue_candidates(processed) do
    results =
      processed
      |> Enum.flat_map(fn
        {:result, %Result{delivery_state: state} = result}
        when state in [:new_staged, :pending_durability] ->
          [result]

        _ ->
          []
      end)

    {:ok, results}
  end

  defp enqueue_all_required_jobs(_event_id, [], _chunk_size, _force_enqueue_failure), do: :ok

  defp enqueue_all_required_jobs(_event_id, _results, _chunk_size, true) do
    {:error,
     %{
       status: :service_unavailable,
       code: "durability_enqueue_failed",
       message: "Unable to queue scan durability handoff: forced failure"
     }}
  end

  defp enqueue_all_required_jobs(event_id, results, chunk_size, false)
       when is_integer(event_id) and event_id > 0 do
    if Enum.all?(results, &(&1.event_id == event_id)) do
      do_enqueue_durability_jobs(event_id, results, chunk_size)
    else
      {:error, durability_enqueue_failed_error("scan batch spans multiple events")}
    end
  end

  defp do_enqueue_durability_jobs(event_id, results, chunk_size) do
    config = ingestion_config()

    jobs =
      results
      |> Enum.chunk_every(chunk_size)
      |> Enum.map(fn chunk ->
        %{results: Enum.map(chunk, &serialize_result/1)}
        |> PersistScanBatchJob.new()
      end)

    Repo.transaction(fn ->
      case lock_event_for_durability_enqueue(event_id) do
        :ok ->
          :ok

        :missing ->
          Repo.rollback(:event_missing_for_durability_enqueue)
      end

      run_durability_enqueue_barrier(config)

      Enum.reduce_while(jobs, [], fn job, acc ->
        case Oban.insert(job) do
          {:ok, inserted_job} -> {:cont, [inserted_job | acc]}
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
    |> case do
      {:ok, _jobs} ->
        :ok

      {:error, :event_missing_for_durability_enqueue} ->
        {:error, durability_enqueue_failed_error("event no longer exists")}

      {:error, reason} ->
        {:error, durability_enqueue_failed_error(inspect(reason))}
    end
  end

  defp lock_event_for_durability_enqueue(event_id) do
    case from(e in Event, where: e.id == ^event_id, lock: "FOR KEY SHARE", select: e.id)
         |> Repo.one() do
      nil -> :missing
      _event_id -> :ok
    end
  end

  defp run_durability_enqueue_barrier(config) do
    case Map.get(config, :durability_enqueue_barrier) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp durability_enqueue_failed_error(detail) do
    %{
      status: :service_unavailable,
      code: "durability_enqueue_failed",
      message: "Unable to queue scan durability handoff: #{detail}"
    }
  end

  defp serialize_result(%Result{} = result) do
    %{
      event_id: result.event_id,
      attendee_id: result.attendee_id,
      idempotency_key: result.idempotency_key,
      ticket_code: result.ticket_code,
      direction: result.direction,
      status: result.status,
      reason_code: result.reason_code,
      message: result.message,
      entrance_name: result.entrance_name,
      operator_name: result.operator_name,
      scanned_at: maybe_iso8601(result.scanned_at),
      processed_at: maybe_iso8601(result.processed_at),
      hot_state_version: result.hot_state_version,
      metadata: result.metadata
    }
  end

  defp maybe_iso8601(nil), do: nil
  defp maybe_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp promote_results(store, results, namespace) do
    case store.promote_results(results, namespace) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Authoritative result promotion failed: #{inspect(reason)}")

        {:error,
         %{
           status: :service_unavailable,
           code: "scan_result_promotion_failed",
           message: "Unable to finalize acknowledged scan results"
         }}
    end
  end

  defp invalid_scan_api_result(scan, reason) do
    %{
      idempotency_key: Map.get(scan, "idempotency_key", "unknown"),
      status: "error",
      message: reason
    }
  end

  defp hot_state_error(:build_timeout) do
    %{
      status: :service_unavailable,
      code: "scan_hot_state_unavailable",
      message: "Unable to prepare event scan state. Please retry."
    }
  end

  defp hot_state_error(reason) do
    Logger.error("Authoritative hot-state evaluation failed: #{inspect(reason)}")

    %{
      status: :service_unavailable,
      code: "scan_ingestion_failed",
      message: "Unable to evaluate scan hot state"
    }
  end

  defp ingestion_config do
    config = Application.get_env(:fastcheck, :mobile_scan_ingestion, [])

    %{
      chunk_size: Keyword.get(config, :chunk_size, 100),
      live_namespace: Keyword.get(config, :live_namespace, "live"),
      store: Keyword.get(config, :store, FastCheck.Scans.HotState.RedisStore),
      force_enqueue_failure: Keyword.get(config, :force_enqueue_failure, false),
      durability_enqueue_barrier: Keyword.get(config, :durability_enqueue_barrier)
    }
  end
end
