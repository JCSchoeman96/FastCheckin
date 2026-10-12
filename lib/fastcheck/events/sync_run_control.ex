defmodule FastCheck.Events.SyncRunControl do
  @moduledoc "Controls the current active SyncRun using caller supplied authority."

  import Ecto.Query

  alias FastCheck.Events.{Cache, Event, SyncLog, SyncState}
  alias FastCheck.Repo

  @active_statuses ["in_progress", "paused"]

  def pause(event_id, authority_guard), do: control(event_id, authority_guard, :paused)
  def resume(event_id, authority_guard), do: control(event_id, authority_guard, :resumed)
  def cancel(event_id, authority_guard), do: control(event_id, authority_guard, :cancelled)

  def subscribe(event_id, sync_run_id) when is_integer(event_id) and is_binary(sync_run_id) do
    Phoenix.PubSub.subscribe(FastCheck.PubSub, topic(event_id, sync_run_id))
  end

  def subscribe(_event_id, _sync_run_id), do: {:error, :invalid_owner}

  defp control(event_id, authority_guard, action)
       when is_integer(event_id) and is_function(authority_guard, 1) do
    with :ok <- check_authority(authority_guard, event_id),
         {:ok, {run, status}} <- transition(event_id, action) do
      update_hot_state(event_id, run, status)

      if action == :cancelled do
        _ = Cache.invalidate_event_cache(event_id)
        _ = Cache.invalidate_events_list_cache()
      end

      Phoenix.PubSub.broadcast(FastCheck.PubSub, topic(event_id, run.sync_run_id), {
        :sync_run_control,
        event_id,
        run.sync_run_id,
        action
      })

      :ok
    end
  end

  defp control(_event_id, _authority_guard, _action), do: {:error, :authority_required}

  defp transition(event_id, action) do
    Repo.transaction(fn ->
      event =
        Repo.one(from row in Event, where: row.id == ^event_id, lock: "FOR UPDATE")

      if is_nil(event), do: Repo.rollback(:not_found)
      if event.status == "archived", do: Repo.rollback(:event_archived)

      runs =
        Repo.all(
          from run in SyncLog,
            where: run.event_id == ^event_id and run.status in ^@active_statuses,
            order_by: run.id,
            lock: "FOR UPDATE"
        )

      case runs do
        [] -> Repo.rollback(:not_found)
        [_, _ | _] -> Repo.rollback(:inconsistent_active_runs)
        [run] -> transition_locked(event, run, action)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_locked(event, run, action) do
    now = database_now()

    if is_nil(run.lease_expires_at) or DateTime.compare(run.lease_expires_at, now) != :gt do
      Repo.rollback(:lease_expired)
    else
      apply_transition(event, run, action, now)
    end
  end

  defp apply_transition(_event, %{status: "paused"} = run, :paused, _now),
    do: {run, :paused}

  defp apply_transition(_event, %{status: "in_progress"} = run, :paused, _now),
    do: {update_run!(run, %{status: "paused"}), :paused}

  defp apply_transition(_event, %{status: "in_progress"} = run, :resumed, _now),
    do: {run, :running}

  defp apply_transition(_event, %{status: "paused"} = run, :resumed, _now),
    do: {update_run!(run, %{status: "in_progress"}), :running}

  defp apply_transition(event, run, :cancelled, now) do
    cancelled =
      update_run!(run, %{
        status: "cancelled",
        completed_at: DateTime.truncate(now, :second),
        error_message: "user_cancelled",
        duration_ms: elapsed_ms(run.started_at, now)
      })

    if event.status == "syncing" do
      event |> Ecto.Changeset.change(%{status: "active"}) |> Repo.update!()
    end

    {cancelled, :cancelled}
  end

  defp apply_transition(_event, _run, _action, _now),
    do: Repo.rollback(:terminal_state)

  defp update_run!(run, attrs) do
    case run |> Ecto.Changeset.change(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, _changeset} -> Repo.rollback(:transition_failed)
    end
  end

  defp update_hot_state(event_id, run, :paused),
    do: SyncState.pause_sync(event_id, run.sync_run_id, run.owner_token)

  defp update_hot_state(event_id, run, :running),
    do: SyncState.resume_sync(event_id, run.sync_run_id, run.owner_token)

  defp update_hot_state(event_id, run, :cancelled),
    do: SyncState.clear_state(event_id, run.sync_run_id, run.owner_token)

  defp check_authority(authority_guard, event_id) do
    case authority_guard.(event_id) do
      :ok -> :ok
      _ -> {:error, :authority_revoked}
    end
  rescue
    _ -> {:error, :authority_revoked}
  catch
    _, _ -> {:error, :authority_revoked}
  end

  defp topic(event_id, sync_run_id), do: "sync_run:#{event_id}:#{sync_run_id}"

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
end
