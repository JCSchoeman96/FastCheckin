defmodule FastCheck.Events.SyncRun do
  @moduledoc """
  Durable Postgres ownership infrastructure for event sync runs.

  This module is not an authorization boundary. Callers must establish server-side
  authority before using these primitives. Ownership decisions use the primary
  Postgres database and require the exact event, run UUID, and fencing token.
  """

  import Ecto.Query
  import Ecto.Changeset, only: [change: 2]

  alias FastCheck.Events.{Cache, Event, SyncLog}
  alias FastCheck.Repo

  @lease_ttl_seconds 180
  @active_statuses ["in_progress", "paused"]
  @terminal_statuses ["completed", "failed", "cancelled"]
  @cancel_reasons [:user_cancelled, :authority_revoked]
  @failure_reasons [:worker_failed, :lease_expired]

  @doc "Claims a durable run. The run and owner UUIDs are generated before the transaction."
  def claim(event_id) when is_integer(event_id) do
    sync_run_id = Ecto.UUID.generate()
    owner_token = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        case lock_event(event_id) do
          nil -> Repo.rollback(:not_found)
          %Event{status: "archived"} -> Repo.rollback(:event_archived)
          event -> claim_locked(event, sync_run_id, owner_token)
        end
      end)

    case result do
      {:ok, run} ->
        invalidate_event_caches(event_id)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def claim(_event_id), do: {:error, :not_found}

  @doc "Checks exact durable ownership against the primary database clock."
  def check_owner(event_id, sync_run_id, owner_token) do
    case Repo.get(Event, event_id) do
      nil ->
        {:error, :not_found}

      %Event{} ->
        case find_run(event_id, sync_run_id) do
          nil ->
            {:error, :stale_owner}

          run ->
            with :ok <- validate_token(run, owner_token),
                 :ok <- validate_active(run) do
              validate_live_lease(run, database_now())
            end
        end
    end
  end

  @doc """
  Renews the lease at a request boundary only when this exact owner is still active.

  Unlike `check_owner/3`, a paused run cannot prepare another external request.
  """
  def prepare_request(event_id, sync_run_id, owner_token) do
    result =
      Repo.transaction(fn ->
        case lock_owned_run(event_id, sync_run_id, owner_token) do
          {:ok, run} ->
            now = database_now()

            with :ok <- validate_token(run, owner_token),
                 :ok <- validate_request_status(run),
                 :ok <- validate_live_lease(run, now) do
              {:ok, updated_run} =
                update_run!(run, %{
                  heartbeat_at: now,
                  lease_expires_at: DateTime.add(now, @lease_ttl_seconds, :second)
                })

              updated_run
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Renews a live run lease without allowing an expired lease to return."
  def renew_lease(event_id, sync_run_id, owner_token) do
    mutate_owned_run(event_id, sync_run_id, owner_token, fn run, now ->
      with :ok <- validate_active(run),
           :ok <- validate_live_lease(run, now) do
        update_run!(run, %{
          heartbeat_at: now,
          lease_expires_at: DateTime.add(now, @lease_ttl_seconds, :second)
        })
      end
    end)
  end

  @doc "Writes durable progress for a live exact owner."
  def update_progress(event_id, sync_run_id, owner_token, page, total_pages, attendees_synced)
      when is_integer(page) and page >= 0 and
             (is_nil(total_pages) or (is_integer(total_pages) and total_pages >= 0)) and
             is_integer(attendees_synced) and attendees_synced >= 0 do
    mutate_owned_run(event_id, sync_run_id, owner_token, fn run, now ->
      with :ok <- validate_active(run),
           :ok <- validate_live_lease(run, now) do
        update_run!(run, %{
          pages_processed: page,
          total_pages: total_pages,
          attendees_synced: attendees_synced
        })
      end
    end)
  end

  def update_progress(
        _event_id,
        _sync_run_id,
        _owner_token,
        _page,
        _total_pages,
        _attendees_synced
      ),
      do: {:error, :invalid_progress}

  @doc "Pauses a live owned run. Repeating pause on the same owner is idempotent."
  def pause(event_id, sync_run_id, owner_token) do
    mutate_owned_run(event_id, sync_run_id, owner_token, fn run, now ->
      with :ok <- validate_active(run),
           :ok <- validate_live_lease(run, now) do
        case run.status do
          "in_progress" -> update_run!(run, %{status: "paused"})
          "paused" -> {:ok, run}
          _ -> {:error, :terminal_state}
        end
      end
    end)
  end

  @doc "Resumes a live owned run. Repeating resume on the same owner is idempotent."
  def resume(event_id, sync_run_id, owner_token) do
    mutate_owned_run(event_id, sync_run_id, owner_token, fn run, now ->
      with :ok <- validate_active(run),
           :ok <- validate_live_lease(run, now) do
        case run.status do
          "paused" -> update_run!(run, %{status: "in_progress"})
          "in_progress" -> {:ok, run}
          _ -> {:error, :terminal_state}
        end
      end
    end)
  end

  @doc "Cancels a run with one of the frozen safe reason codes."
  def cancel(event_id, sync_run_id, owner_token, reason) when reason in @cancel_reasons do
    terminalize(
      event_id,
      sync_run_id,
      owner_token,
      "cancelled",
      Atom.to_string(reason),
      %{},
      false,
      true
    )
  end

  def cancel(_event_id, _sync_run_id, _owner_token, _reason), do: {:error, :invalid_reason}

  @doc "Completes an owned run successfully and records the event completion time."
  def complete(event_id, sync_run_id, owner_token, attendees_synced, pages_processed)
      when is_integer(attendees_synced) and attendees_synced >= 0 and is_integer(pages_processed) and
             pages_processed >= 0 do
    terminalize(
      event_id,
      sync_run_id,
      owner_token,
      "completed",
      nil,
      %{attendees_synced: attendees_synced, pages_processed: pages_processed},
      true,
      false
    )
  end

  def complete(_event_id, _sync_run_id, _owner_token, _attendees_synced, _pages_processed),
    do: {:error, :invalid_progress}

  @doc "Fails an owned run with a bounded safe reason code."
  def fail(event_id, sync_run_id, owner_token, reason, pages_processed)
      when reason in @failure_reasons and is_integer(pages_processed) and pages_processed >= 0 do
    terminalize(
      event_id,
      sync_run_id,
      owner_token,
      "failed",
      Atom.to_string(reason),
      %{pages_processed: pages_processed},
      false,
      false
    )
  end

  def fail(_event_id, _sync_run_id, _owner_token, _reason, _pages_processed),
    do: {:error, :invalid_reason}

  defp claim_locked(event, sync_run_id, owner_token) do
    now = database_now()

    active_runs =
      Repo.all(
        from run in SyncLog,
          where: run.event_id == ^event.id and run.status in ^@active_statuses,
          order_by: run.id,
          lock: "FOR UPDATE"
      )

    case active_runs do
      [_, _ | _] ->
        Repo.rollback(:inconsistent_active_runs)

      [run] ->
        claim_with_active_run(event, run, sync_run_id, owner_token, now)

      [] ->
        if event.status == "syncing" do
          Repo.rollback(:inconsistent_syncing_event)
        else
          insert_claimed_run(event, sync_run_id, owner_token, now)
        end
    end
  end

  defp claim_with_active_run(event, run, sync_run_id, owner_token, now) do
    if is_nil(run.lease_expires_at) or DateTime.compare(run.lease_expires_at, now) == :gt do
      Repo.rollback(:sync_already_running)
    else
      terminalize_expired_run!(run, now)
      insert_claimed_run(event, sync_run_id, owner_token, now)
    end
  end

  defp terminalize_expired_run!(run, now) do
    update_run!(run, %{
      status: "failed",
      completed_at: DateTime.truncate(now, :second),
      error_message: "lease_expired",
      duration_ms: elapsed_ms(run.started_at, now)
    })
  end

  defp insert_claimed_run(event, sync_run_id, owner_token, now) do
    run = %SyncLog{
      event_id: event.id,
      sync_run_id: sync_run_id,
      owner_token: owner_token,
      status: "in_progress",
      started_at: DateTime.truncate(now, :second),
      heartbeat_at: now,
      lease_expires_at: DateTime.add(now, @lease_ttl_seconds, :second),
      pages_processed: 0,
      attendees_synced: 0
    }

    case Repo.insert(run) do
      {:ok, inserted} ->
        update_event!(event, %{
          status: "syncing",
          sync_started_at: DateTime.truncate(now, :second)
        })

        Repo.get!(SyncLog, inserted.id)

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp mutate_owned_run(event_id, sync_run_id, owner_token, mutation) do
    result =
      Repo.transaction(fn ->
        case lock_owned_run(event_id, sync_run_id, owner_token) do
          {:ok, run} ->
            now = database_now()

            case mutation.(run, now) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminalize(
         event_id,
         sync_run_id,
         owner_token,
         status,
         reason,
         extra,
         success?,
         idempotent_cancel?
       ) do
    result =
      Repo.transaction(fn ->
        event = lock_event(event_id)
        if is_nil(event), do: Repo.rollback(:not_found)

        case lock_owned_run(event_id, sync_run_id, owner_token) do
          {:ok, %{status: "cancelled"} = run} when idempotent_cancel? ->
            run

          {:ok, run} ->
            now = database_now()

            with :ok <- validate_active(run),
                 :ok <- validate_live_lease(run, now) do
              completed_at = DateTime.truncate(now, :second)

              updates =
                Map.merge(extra, %{
                  status: status,
                  completed_at: completed_at,
                  error_message: reason,
                  duration_ms: elapsed_ms(run.started_at, now)
                })

              {:ok, updated_run} = update_run!(run, updates)
              event_updates = terminal_event_updates(event, completed_at, success?)
              if map_size(event_updates) > 0, do: update_event!(event, event_updates)
              Repo.get!(SyncLog, updated_run.id)
            else
              {:error, error} -> Repo.rollback(error)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        invalidate_event_caches(event_id)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminal_event_updates(%Event{status: "syncing"}, completed_at, true),
    do: %{
      status: "active",
      sync_completed_at: completed_at,
      last_sync_at: completed_at,
      last_soft_sync_at: completed_at
    }

  defp terminal_event_updates(%Event{status: "syncing"}, completed_at, false),
    do: %{status: "active", last_soft_sync_at: completed_at}

  defp terminal_event_updates(_event, completed_at, true),
    do: %{
      sync_completed_at: completed_at,
      last_sync_at: completed_at,
      last_soft_sync_at: completed_at
    }

  defp terminal_event_updates(_event, completed_at, false), do: %{last_soft_sync_at: completed_at}

  defp lock_owned_run(event_id, sync_run_id, owner_token) do
    run =
      Repo.one(
        from row in SyncLog,
          where: row.event_id == ^event_id and row.sync_run_id == ^sync_run_id,
          lock: "FOR UPDATE"
      )

    cond do
      is_nil(run) -> {:error, :stale_owner}
      run.owner_token != owner_token -> {:error, :stale_owner}
      true -> {:ok, run}
    end
  end

  defp lock_event(event_id),
    do: Repo.one(from event in Event, where: event.id == ^event_id, lock: "FOR UPDATE")

  defp find_run(event_id, sync_run_id),
    do:
      Repo.one(
        from run in SyncLog, where: run.event_id == ^event_id and run.sync_run_id == ^sync_run_id
      )

  defp validate_token(%SyncLog{owner_token: token}, token), do: :ok
  defp validate_token(%SyncLog{}, _token), do: {:error, :stale_owner}

  defp validate_active(%SyncLog{status: status}) when status in @active_statuses, do: :ok

  defp validate_active(%SyncLog{status: status}) when status in @terminal_statuses,
    do: {:error, :terminal_state}

  defp validate_active(%SyncLog{}), do: {:error, :terminal_state}

  defp validate_request_status(%SyncLog{status: "in_progress"}), do: :ok
  defp validate_request_status(%SyncLog{status: "paused"}), do: {:error, :paused}
  defp validate_request_status(%SyncLog{}), do: {:error, :terminal_state}

  defp validate_live_lease(%SyncLog{lease_expires_at: expires}, now) do
    if DateTime.compare(expires, now) == :gt, do: :ok, else: {:error, :lease_expired}
  end

  defp update_run!(run, attrs) do
    changeset = change(run, attrs)

    case Repo.update(changeset) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_event!(event, attrs) do
    changeset = change(event, attrs)

    case Repo.update(changeset) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
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

  defp invalidate_event_caches(event_id) do
    _ = Cache.invalidate_event_cache(event_id)
    _ = Cache.invalidate_events_list_cache()
    :ok
  end
end
