defmodule FastCheck.Events.SyncRunControlTest do
  use FastCheck.DataCase, async: false

  import FastCheck.Fixtures

  alias FastCheck.Events.{Event, SyncLog, SyncRun, SyncRunControl, SyncState}
  alias FastCheck.Repo

  test "pause and resume mutate the durable owner before mirroring and notifying" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    :ok = SyncState.init_sync(event.id, run.sync_run_id, run.owner_token, run.id)
    :ok = SyncRunControl.subscribe(event.id, run.sync_run_id)

    assert :ok = SyncRunControl.pause(event.id, &allow_event/1)
    assert Repo.get!(SyncLog, run.id).status == "paused"

    assert {:ok, %{status: :paused}} =
             SyncState.get_state(event.id, run.sync_run_id, run.owner_token)

    assert_receive {:sync_run_control, event_id, sync_run_id, :paused}
    assert {event_id, sync_run_id} == {event.id, run.sync_run_id}
    refute_received {:sync_run_control, _, _, _, _}

    assert :ok = SyncRunControl.resume(event.id, &allow_event/1)
    resumed = Repo.get!(SyncLog, run.id)
    assert resumed.status == "in_progress"
    assert resumed.sync_run_id == run.sync_run_id
    assert resumed.owner_token == run.owner_token

    assert {:ok, %{status: :running}} =
             SyncState.get_state(event.id, run.sync_run_id, run.owner_token)

    assert_receive {:sync_run_control, ^event_id, ^sync_run_id, :resumed}
  end

  test "cancel requires current caller authority and leaves no browser supplied owner" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    :ok = SyncState.init_sync(event.id, run.sync_run_id, run.owner_token, run.id)

    assert {:error, :authority_revoked} =
             SyncRunControl.cancel(event.id, fn _event_id -> {:error, :revoked} end)

    assert Repo.get!(SyncLog, run.id).status == "in_progress"
    assert :ok = SyncRunControl.cancel(event.id, &allow_event/1)
    cancelled = Repo.get!(SyncLog, run.id)
    assert cancelled.status == "cancelled"
    assert cancelled.error_message == "user_cancelled"
    assert Repo.get!(Event, event.id).status == "active"
    assert {:error, :not_found} = SyncState.get_state(event.id, run.sync_run_id, run.owner_token)
  end

  test "fails closed for no active run, multiple active rows, and expired lease" do
    event = create_event()
    assert {:error, :not_found} = SyncRunControl.pause(event.id, &allow_event/1)

    event_with_runs = create_event()
    first = insert_active_run(event_with_runs.id, "in_progress")
    _second = insert_active_run(event_with_runs.id, "paused")

    assert {:error, :inconsistent_active_runs} =
             SyncRunControl.cancel(event_with_runs.id, &allow_event/1)

    assert Repo.get!(SyncLog, first.id).status == "in_progress"

    expired_event = create_event()
    expired = insert_active_run(expired_event.id, "paused", expired: true)
    assert {:error, :lease_expired} = SyncRunControl.resume(expired_event.id, &allow_event/1)
    assert Repo.get!(SyncLog, expired.id).status == "paused"
  end

  test "the guarded Events facade exposes only event id and server guard" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)

    assert :ok = FastCheck.Events.pause_sync_guarded(event.id, &allow_event/1)
    assert Repo.get!(SyncLog, run.id).status == "paused"
  end

  defp allow_event(_event_id), do: :ok

  defp insert_active_run(event_id, status, opts \\ []) do
    now = DateTime.utc_now()
    started_at = DateTime.truncate(now, :second)

    lease =
      if Keyword.get(opts, :expired, false),
        do: DateTime.add(now, -1, :second),
        else: DateTime.add(now, 180, :second)

    {:ok, run} =
      %SyncLog{}
      |> Ecto.Changeset.change(%{
        event_id: event_id,
        sync_run_id: Ecto.UUID.generate(),
        owner_token: Ecto.UUID.generate(),
        started_at: started_at,
        heartbeat_at: now,
        lease_expires_at: lease,
        status: status
      })
      |> Repo.insert()

    run
  end
end
