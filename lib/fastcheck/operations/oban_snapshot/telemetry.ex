defmodule FastCheck.Operations.ObanSnapshot.Telemetry do
  @moduledoc """
  Telemetry emitters for the replicated global Oban snapshot gauges.
  """

  alias FastCheck.Operations.ObanSnapshot
  alias FastCheck.Operations.ObanSnapshot.Clock

  @error_reasons ~w(
    lease_unavailable
    snapshot_write_failed
    snapshot_read_failed
    db_collection_failed
    invalid_shared_snapshot
  )a

  @spec emit_full_snapshot(map()) :: :ok | {:error, term()}
  def emit_full_snapshot(snapshot) do
    with {:ok, normalized} <- ObanSnapshot.normalize(snapshot) do
      Enum.each(normalized.queues, &emit_queue/1)
      :ok
    end
  end

  @spec emit_freshness(map(), DateTime.t()) :: :ok
  def emit_freshness(state, now \\ Clock.utc_now()) do
    age =
      case Map.get(state, :accepted_collected_at) do
        %DateTime{} = collected_at ->
          max(DateTime.diff(now, collected_at, :microsecond) / 1_000_000, 0)

        _ ->
          0
      end

    lifecycle = Map.get(state, :lifecycle, :uninitialized)

    freshness =
      case {lifecycle, Map.get(state, :accepted_collected_at)} do
        {:current, %DateTime{}} -> 1
        {:stale, %DateTime{}} -> 0.5
        {:unavailable, %DateTime{}} -> 0
        _ -> 0
      end

    :telemetry.execute([:fastcheck, :operations, :oban, :snapshot_age_seconds], %{value: age})
    :telemetry.execute([:fastcheck, :operations, :oban, :snapshot_freshness], %{value: freshness})
    :ok
  end

  @spec emit_error(atom()) :: :ok
  def emit_error(reason) when reason in @error_reasons do
    :telemetry.execute(
      [:fastcheck, :operations, :oban, :collection_errors_total],
      %{count: 1},
      %{reason: reason}
    )

    :ok
  end

  def emit_error(_reason), do: :ok

  defp emit_queue(row) do
    for state <- ObanSnapshot.states() do
      :telemetry.execute(
        [:fastcheck, :operations, :oban, :jobs],
        %{value: Map.fetch!(row, String.to_existing_atom(state))},
        %{queue: row.queue, state: state}
      )
    end

    for state <- ~w(available executing retryable) do
      :telemetry.execute(
        [:fastcheck, :operations, :oban, :oldest_age_seconds],
        %{value: Map.fetch!(row, String.to_existing_atom("oldest_#{state}_age_seconds"))},
        %{queue: row.queue, state: state}
      )
    end

    :telemetry.execute(
      [:fastcheck, :operations, :oban, :next_scheduled_in_seconds],
      %{value: row.next_scheduled_in_seconds},
      %{queue: row.queue}
    )

    :telemetry.execute(
      [:fastcheck, :operations, :oban, :discarded_recent],
      %{value: row.discarded_recent_count},
      %{queue: row.queue}
    )
  end
end
