defmodule FastCheck.Load.MobileEventCleanup do
  @moduledoc """
  Removes seeded mobile performance events and their related durable and hot-state data.
  """

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.CheckIn
  alias FastCheck.Events.Event
  alias FastCheck.Load.MobileEventSeed
  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo
  alias FastCheck.Scans.ScanAttempt

  @redis_key_count 500
  @redis_prefix "fastcheck:mobile_scans"

  @type delete_counts :: %{
          attendees: non_neg_integer(),
          check_ins: non_neg_integer(),
          events: non_neg_integer(),
          mobile_idempotency_logs: non_neg_integer(),
          oban_jobs: non_neg_integer(),
          scan_attempts: non_neg_integer()
        }

  @type redis_result :: %{
          deleted_keys: non_neg_integer(),
          status: :ok | :skipped,
          strategy: :flushdb | :targeted
        }

  @type cleanup_result :: %{
          deleted: delete_counts(),
          event_ids: [integer()],
          redis: redis_result()
        }

  @spec cleanup(keyword() | map()) :: {:ok, cleanup_result()} | {:error, String.t()}
  def cleanup(opts) when is_list(opts) or is_map(opts) do
    opts = normalize_options(opts)

    with {:ok, event_ids} <- resolve_event_ids(opts),
         {:ok, deleted} <- delete_event_data(event_ids),
         {:ok, redis} <- cleanup_redis(event_ids, opts) do
      {:ok, %{event_ids: event_ids, deleted: deleted, redis: redis}}
    end
  end

  @spec cleanup!(keyword() | map()) :: cleanup_result()
  def cleanup!(opts) do
    case cleanup(opts) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "unable to clean mobile perf data: #{reason}"
    end
  end

  defp normalize_options(opts) when is_map(opts), do: Enum.into(opts, [])
  defp normalize_options(opts), do: opts

  defp resolve_event_ids(opts) do
    cond do
      opts[:event_id] ->
        with {:ok, event_id} <-
               parse_positive_integer(opts[:event_id], "--event-id must be positive") do
          {:ok, [event_id]}
        end

      opts[:manifest] ->
        resolve_event_ids_from_manifest(opts[:manifest])

      true ->
        {:ok, marker_event_ids()}
    end
  end

  # Internal CLI helper: the operator intentionally supplies the manifest path.
  # sobelow_skip ["Traversal"]
  defp resolve_event_ids_from_manifest(path) when is_binary(path) do
    with {:ok, body} <- File.read(Path.expand(path)),
         {:ok, manifest} <- Jason.decode(body),
         {:ok, event_id} <-
           parse_positive_integer(manifest["event_id"], "manifest missing event_id") do
      {:ok, [event_id]}
    else
      {:error, :enoent} -> {:error, "manifest not found: #{path}"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "unable to read manifest: #{inspect(reason)}"}
    end
  end

  defp resolve_event_ids_from_manifest(_path), do: {:error, "--manifest must be a file path"}

  defp marker_event_ids do
    seed_site_url = MobileEventSeed.seed_site_url()

    Repo.all(
      from event in Event,
        where: event.site_url == ^seed_site_url and event.tickera_site_url == ^seed_site_url,
        order_by: [asc: event.id],
        select: event.id
    )
  end

  defp delete_event_data([]), do: {:ok, empty_delete_counts()}

  defp delete_event_data(event_ids) do
    Repo.transaction(
      fn ->
        %{
          oban_jobs: delete_oban_jobs(event_ids),
          mobile_idempotency_logs:
            delete_all(from(log in MobileIdempotencyLog, where: log.event_id in ^event_ids)),
          scan_attempts:
            delete_all(
              from(scan_attempt in ScanAttempt, where: scan_attempt.event_id in ^event_ids)
            ),
          check_ins:
            delete_all(from(check_in in CheckIn, where: check_in.event_id in ^event_ids)),
          attendees:
            delete_all(from(attendee in Attendee, where: attendee.event_id in ^event_ids)),
          events: delete_all(from(event in Event, where: event.id in ^event_ids))
        }
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, deleted} -> {:ok, deleted}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp delete_oban_jobs(event_ids) do
    Enum.reduce(event_ids, 0, fn event_id, total ->
      total + delete_all(scan_persistence_jobs_query(event_id))
    end)
  end

  defp scan_persistence_jobs_query(event_id) do
    from job in "oban_jobs",
      where: field(job, :queue) == "scan_persistence",
      where:
        fragment(
          """
          exists (
            select 1
            from jsonb_array_elements(?->'results') as elem
            where (elem->>'event_id')::bigint = ?
          )
          """,
          field(job, :args),
          ^event_id
        )
  end

  defp cleanup_redis(event_ids, opts) do
    strategy = if opts[:flush_redis], do: :flushdb, else: :targeted

    case Process.whereis(FastCheck.Redix) do
      pid when is_pid(pid) ->
        case strategy do
          :flushdb ->
            case Redix.command(FastCheck.Redix, ["FLUSHDB"]) do
              {:ok, "OK"} ->
                {:ok, %{deleted_keys: 0, status: :ok, strategy: :flushdb}}

              {:error, %Redix.ConnectionError{reason: :closed}} ->
                {:ok, %{deleted_keys: 0, status: :skipped, strategy: :flushdb}}

              {:error, reason} ->
                {:error, "unable to flush redis: #{inspect(reason)}"}
            end

          :targeted ->
            case delete_targeted_redis_keys(event_ids) do
              {:ok, deleted_keys} ->
                {:ok, %{deleted_keys: deleted_keys, status: :ok, strategy: :targeted}}

              {:error, %Redix.ConnectionError{reason: :closed}} ->
                {:ok, %{deleted_keys: 0, status: :skipped, strategy: :targeted}}

              {:error, reason} ->
                {:error, reason}
            end
        end

      _ ->
        {:ok, %{deleted_keys: 0, status: :skipped, strategy: strategy}}
    end
  end

  defp delete_targeted_redis_keys(event_ids) do
    event_ids
    |> Enum.reduce_while({:ok, 0}, fn event_id, {:ok, total} ->
      pattern = "#{@redis_prefix}:*:event:#{event_id}:*"

      with {:ok, keys} <- scan_redis_keys(pattern),
           {:ok, deleted} <- delete_redis_keys(keys) do
        {:cont, {:ok, total + deleted}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp scan_redis_keys(pattern), do: do_scan_redis_keys("0", pattern, MapSet.new())

  defp do_scan_redis_keys(cursor, pattern, keys) do
    case Redix.command(FastCheck.Redix, [
           "SCAN",
           cursor,
           "MATCH",
           pattern,
           "COUNT",
           Integer.to_string(@redis_key_count)
         ]) do
      {:ok, [next_cursor, batch]} ->
        updated_keys = Enum.reduce(batch, keys, &MapSet.put(&2, &1))

        if next_cursor == "0" do
          {:ok, MapSet.to_list(updated_keys)}
        else
          do_scan_redis_keys(next_cursor, pattern, updated_keys)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_redis_keys([]), do: {:ok, 0}

  defp delete_redis_keys(keys) do
    case Redix.command(FastCheck.Redix, ["DEL" | keys]) do
      {:ok, deleted} when is_integer(deleted) -> {:ok, deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_all(query) do
    query
    |> Repo.delete_all(timeout: :infinity)
    |> elem(0)
  end

  defp empty_delete_counts do
    %{
      attendees: 0,
      check_ins: 0,
      events: 0,
      mobile_idempotency_logs: 0,
      oban_jobs: 0,
      scan_attempts: 0
    }
  end

  defp parse_positive_integer(value, _message) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_positive_integer(value, message) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, message}
    end
  end

  defp parse_positive_integer(_value, message), do: {:error, message}
end
