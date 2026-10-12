defmodule FastCheck.Events.SyncRunRecovery do
  @moduledoc "Fails expired active SyncRuns without starting external work."

  import Ecto.Query

  alias FastCheck.Events.{Cache, Event, SyncLog, SyncState}
  alias FastCheck.Repo

  @max_batch_size 100

  def recover_expired(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @max_batch_size) |> normalize_limit()

    candidates =
      Repo.all(
        from run in SyncLog,
          where:
            run.status in ["in_progress", "paused"] and
              not is_nil(run.lease_expires_at) and
              run.lease_expires_at <= fragment("clock_timestamp()"),
          order_by: [asc: run.lease_expires_at, asc: run.id],
          limit: ^limit,
          select: {run.event_id, run.id}
      )

    Enum.reduce(candidates, %{recovered: 0, skipped: 0}, fn {event_id, sync_log_id}, result ->
      case recover_one(event_id, sync_log_id) do
        {:recovered, run} ->
          _ = SyncState.clear_state(event_id, run.sync_run_id, run.owner_token)
          _ = Cache.invalidate_event_cache(event_id)
          _ = Cache.invalidate_events_list_cache()
          %{result | recovered: result.recovered + 1}

        :skipped ->
          %{result | skipped: result.skipped + 1}
      end
    end)
  end

  defp recover_one(event_id, sync_log_id) do
    Repo.transaction(fn ->
      event =
        Repo.one(
          from row in Event,
            where: row.id == ^event_id,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      if is_nil(event) do
        Repo.rollback(:skip)
      end

      run =
        Repo.one(
          from row in SyncLog,
            where: row.id == ^sync_log_id and row.event_id == ^event_id,
            lock: "FOR UPDATE SKIP LOCKED"
        )

      now = database_now()

      if is_nil(run) or run.status not in ["in_progress", "paused"] or
           is_nil(run.lease_expires_at) or DateTime.compare(run.lease_expires_at, now) == :gt do
        Repo.rollback(:skip)
      end

      completed_at = DateTime.truncate(now, :second)

      {:ok, failed_run} =
        run
        |> Ecto.Changeset.change(%{
          status: "failed",
          completed_at: completed_at,
          error_message: "lease_expired",
          duration_ms: elapsed_ms(run.started_at, now)
        })
        |> Repo.update()

      if event.status == "syncing" do
        event
        |> Ecto.Changeset.change(%{status: "active"})
        |> Repo.update!()
      end

      failed_run
    end)
    |> case do
      {:ok, run} -> {:recovered, run}
      {:error, :skip} -> :skipped
      {:error, _reason} -> :skipped
    end
  end

  defp database_now do
    %{rows: [[timestamp]]} = Repo.query!("SELECT clock_timestamp()")
    DateTime.from_naive!(timestamp, "Etc/UTC")
  end

  defp elapsed_ms(started_at, now) do
    started_at =
      if match?(%NaiveDateTime{}, started_at),
        do: DateTime.from_naive!(started_at, "Etc/UTC"),
        else: started_at

    max(DateTime.diff(now, started_at, :millisecond), 0)
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0,
    do: min(limit, @max_batch_size)

  defp normalize_limit(_limit), do: @max_batch_size
end
