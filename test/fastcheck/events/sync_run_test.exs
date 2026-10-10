defmodule FastCheck.Events.SyncRunTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events.{Event, SyncLog, SyncRun}
  alias FastCheck.Repo

  import FastCheck.Fixtures
  import Ecto.Query

  @active_statuses ["in_progress", "paused"]

  test "claim persists independent UUID identities and a database-clock lease" do
    event = create_event()
    before_claim = db_now()

    assert {:ok, run} = SyncRun.claim(event.id)
    after_claim = db_now()
    assert {:ok, _} = Ecto.UUID.dump(run.sync_run_id)
    assert {:ok, _} = Ecto.UUID.dump(run.owner_token)
    refute run.sync_run_id == run.owner_token
    assert run.status == "in_progress"
    assert run.started_at
    assert run.heartbeat_at
    assert run.lease_expires_at
    assert DateTime.diff(run.lease_expires_at, run.heartbeat_at, :second) in 179..180
    assert DateTime.compare(run.heartbeat_at, before_claim) in [:gt, :eq]
    assert DateTime.compare(run.heartbeat_at, after_claim) in [:lt, :eq]

    event = Repo.get!(Event, event.id)
    assert event.status == "syncing"
    assert event.sync_started_at
  end

  test "missing and archived events fail closed without creating a run" do
    assert {:error, :not_found} = SyncRun.claim(-1)
    assert Repo.aggregate(SyncLog, :count) == 0

    event = create_event(%{status: "archived"})
    assert {:error, :event_archived} = SyncRun.claim(event.id)
    assert Repo.aggregate(SyncLog, :count) == 0
    assert Repo.get!(Event, event.id).status == "archived"
  end

  test "a live or paused run blocks another claim" do
    event = create_event()
    assert {:ok, run} = SyncRun.claim(event.id)
    assert {:error, :sync_already_running} = SyncRun.claim(event.id)
    assert {:ok, _} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    assert {:error, :sync_already_running} = SyncRun.claim(event.id)
    assert active_count(event.id) == 1
  end

  test "a syncing event without an active run and multiple active rows are inconsistent" do
    syncing = create_event(%{status: "syncing"})
    assert {:error, :inconsistent_syncing_event} = SyncRun.claim(syncing.id)
    assert Repo.get!(Event, syncing.id).status == "syncing"
    assert active_count(syncing.id) == 0

    event = create_event()
    _ = insert_legacy_run(event.id, "in_progress")
    _ = insert_legacy_run(event.id, "paused")
    assert {:error, :inconsistent_active_runs} = SyncRun.claim(event.id)
    assert active_count(event.id) == 2
  end

  test "concurrent claims serialize on the event row" do
    event = create_event()
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :claim -> SyncRun.claim(event.id)
          end
        end)
      end

    for task <- tasks do
      assert_receive {:ready, pid}
      assert pid == task.pid
    end

    Enum.each(tasks, &send(&1.pid, :claim))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :sync_already_running})) == 1
    assert active_count(event.id) == 1
  end

  test "an expired active run is failed before a new row is claimed" do
    event = create_event()
    old = insert_owned_run(event.id, "in_progress", expired: true)

    assert {:ok, new} = SyncRun.claim(event.id)
    old = Repo.get!(SyncLog, old.id)
    assert old.status == "failed"
    assert old.error_message == "lease_expired"
    assert old.completed_at
    refute old.id == new.id
    refute old.sync_run_id == new.sync_run_id
    refute old.owner_token == new.owner_token
    assert new.status == "in_progress"
    assert new.lease_expires_at > new.heartbeat_at
    assert Repo.get!(Event, event.id).status == "syncing"
  end

  test "owner checks require exact event, run, token, active state, and live lease" do
    event = create_event()
    run = claim!(event.id)

    assert :ok = SyncRun.check_owner(event.id, run.sync_run_id, run.owner_token)

    assert {:error, :stale_owner} =
             SyncRun.check_owner(event.id, Ecto.UUID.generate(), run.owner_token)

    assert {:error, :stale_owner} =
             SyncRun.check_owner(event.id, run.sync_run_id, Ecto.UUID.generate())

    assert {:error, :not_found} = SyncRun.check_owner(-1, run.sync_run_id, run.owner_token)
  end

  test "request preparation renews only an in-progress owner's live lease" do
    event = create_event()
    run = claim!(event.id)

    assert {:ok, prepared} = SyncRun.prepare_request(event.id, run.sync_run_id, run.owner_token)
    assert prepared.heartbeat_at >= run.heartbeat_at
    assert DateTime.diff(prepared.lease_expires_at, prepared.heartbeat_at, :second) in 179..180

    assert {:error, :stale_owner} =
             SyncRun.prepare_request(event.id, run.sync_run_id, Ecto.UUID.generate())

    assert {:ok, paused} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)

    assert {:error, :paused} =
             SyncRun.prepare_request(event.id, paused.sync_run_id, paused.owner_token)

    expired = insert_owned_run(event.id, "in_progress", expired: true)

    assert {:error, :lease_expired} =
             SyncRun.prepare_request(event.id, expired.sync_run_id, expired.owner_token)

    assert {:ok, completed} =
             SyncRun.complete(event.id, prepared.sync_run_id, prepared.owner_token, 0, 0)

    assert {:error, :terminal_state} =
             SyncRun.prepare_request(event.id, completed.sync_run_id, completed.owner_token)
  end

  test "wrong run ids and tokens cannot mutate any durable ownership state" do
    event = create_event()
    run = claim!(event.id)
    stale_token = Ecto.UUID.generate()
    stale_run_id = Ecto.UUID.generate()

    mutations = [
      fn id, token -> SyncRun.renew_lease(event.id, id, token) end,
      fn id, token -> SyncRun.update_progress(event.id, id, token, 1, 2, 3) end,
      fn id, token -> SyncRun.pause(event.id, id, token) end,
      fn id, token -> SyncRun.resume(event.id, id, token) end,
      fn id, token -> SyncRun.cancel(event.id, id, token, :user_cancelled) end,
      fn id, token -> SyncRun.complete(event.id, id, token, 3, 1) end,
      fn id, token -> SyncRun.fail(event.id, id, token, :worker_failed, 1) end
    ]

    for mutate <- mutations do
      assert {:error, :stale_owner} = mutate.(run.sync_run_id, stale_token)
      assert {:error, :stale_owner} = mutate.(stale_run_id, run.owner_token)
    end

    unchanged = Repo.get!(SyncLog, run.id)
    assert unchanged.status == "in_progress"
    assert unchanged.pages_processed == 0
    assert unchanged.attendees_synced == 0
    assert unchanged.heartbeat_at == run.heartbeat_at
    assert unchanged.lease_expires_at == run.lease_expires_at
    assert Repo.get!(Event, event.id).status == "syncing"
  end

  test "renewal updates a live lease and rejects expired and terminal owners without writes" do
    event = create_event()
    run = claim!(event.id)
    assert {:ok, renewed} = SyncRun.renew_lease(event.id, run.sync_run_id, run.owner_token)
    assert renewed.heartbeat_at >= run.heartbeat_at
    assert renewed.lease_expires_at > run.lease_expires_at

    expired = insert_owned_run(event.id, "in_progress", expired: true)

    assert {:error, :lease_expired} =
             SyncRun.renew_lease(event.id, expired.sync_run_id, expired.owner_token)

    expired_after = Repo.get!(SyncLog, expired.id)
    assert expired_after.heartbeat_at == expired.heartbeat_at
    assert expired_after.lease_expires_at == expired.lease_expires_at

    assert {:error, :lease_expired} =
             SyncRun.update_progress(event.id, expired.sync_run_id, expired.owner_token, 1, 1, 1)

    assert {:error, :lease_expired} =
             SyncRun.pause(event.id, expired.sync_run_id, expired.owner_token)

    assert {:error, :lease_expired} =
             SyncRun.resume(event.id, expired.sync_run_id, expired.owner_token)

    assert Repo.get!(SyncLog, expired.id).status == "in_progress"

    assert {:ok, completed} = SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 0, 0)

    assert {:error, :terminal_state} =
             SyncRun.renew_lease(event.id, run.sync_run_id, run.owner_token)

    assert Repo.get!(SyncLog, completed.id).heartbeat_at == completed.heartbeat_at
  end

  test "progress is owner-fenced and allowed while running or paused" do
    event = create_event()
    run = claim!(event.id)

    assert {:error, :stale_owner} =
             SyncRun.update_progress(event.id, run.sync_run_id, Ecto.UUID.generate(), 1, 4, 10)

    assert {:error, :stale_owner} =
             SyncRun.update_progress(event.id, Ecto.UUID.generate(), run.owner_token, 1, 4, 10)

    assert Repo.get!(SyncLog, run.id).pages_processed == 0

    assert {:ok, running} =
             SyncRun.update_progress(event.id, run.sync_run_id, run.owner_token, 1, 4, 10)

    assert {running.pages_processed, running.total_pages, running.attendees_synced} == {1, 4, 10}
    assert {:ok, _} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)

    assert {:ok, paused} =
             SyncRun.update_progress(event.id, run.sync_run_id, run.owner_token, 2, 4, 20)

    assert {paused.pages_processed, paused.attendees_synced} == {2, 20}
    assert {:ok, _} = SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 20, 2)

    assert {:error, :terminal_state} =
             SyncRun.update_progress(event.id, run.sync_run_id, run.owner_token, 3, 4, 30)
  end

  test "pause and resume are owner-fenced, idempotent, and preserve identities" do
    event = create_event()
    run = claim!(event.id)
    identity = {run.sync_run_id, run.owner_token}

    assert {:error, :stale_owner} = SyncRun.pause(event.id, run.sync_run_id, Ecto.UUID.generate())
    assert {:ok, paused} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    assert paused.status == "paused"
    assert {:ok, paused_again} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    assert paused_again.status == "paused"
    assert {:ok, resumed} = SyncRun.resume(event.id, run.sync_run_id, run.owner_token)
    assert resumed.status == "in_progress"
    assert {:ok, resumed_again} = SyncRun.resume(event.id, run.sync_run_id, run.owner_token)
    assert resumed_again.status == "in_progress"
    assert {resumed_again.sync_run_id, resumed_again.owner_token} == identity

    assert {:ok, _} = SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 0, 0)
    assert {:error, :terminal_state} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    assert {:error, :terminal_state} = SyncRun.resume(event.id, run.sync_run_id, run.owner_token)
  end

  test "completion records success and only success sets the event completion timestamp" do
    event = create_event()
    run = claim!(event.id)
    assert {:ok, completed} = SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 42, 7)
    event = Repo.get!(Event, event.id)

    assert completed.status == "completed"
    assert completed.attendees_synced == 42
    assert completed.pages_processed == 7
    assert completed.completed_at
    assert completed.duration_ms >= 0
    assert completed.error_message == nil
    assert event.status == "active"
    assert event.sync_completed_at
    assert event.last_sync_at == event.sync_completed_at
    assert event.last_soft_sync_at == event.sync_completed_at
  end

  test "failure stores safe reasons and does not set sync completion time" do
    event = create_event()
    run = claim!(event.id)

    assert {:error, :stale_owner} =
             SyncRun.fail(event.id, run.sync_run_id, Ecto.UUID.generate(), :worker_failed, 3)

    assert {:ok, failed} =
             SyncRun.fail(event.id, run.sync_run_id, run.owner_token, :worker_failed, 3)

    event = Repo.get!(Event, event.id)

    assert failed.status == "failed"
    assert failed.error_message == "worker_failed"
    assert failed.pages_processed == 3
    assert failed.completed_at
    assert event.status == "active"
    assert is_nil(event.sync_completed_at)
    assert event.last_soft_sync_at

    assert {:error, :terminal_state} =
             SyncRun.fail(event.id, run.sync_run_id, run.owner_token, :lease_expired, 4)
  end

  test "cancellation persists only the supported canonical reasons" do
    for reason <- [:user_cancelled, :authority_revoked] do
      event = create_event()
      run = claim!(event.id)

      assert {:error, :stale_owner} =
               SyncRun.cancel(event.id, run.sync_run_id, Ecto.UUID.generate(), reason)

      assert {:ok, cancelled} = SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, reason)
      event = Repo.get!(Event, event.id)

      assert cancelled.status == "cancelled"
      assert cancelled.error_message == Atom.to_string(reason)
      assert cancelled.completed_at
      assert event.status == "active"
      assert is_nil(event.sync_completed_at)

      assert {:ok, ^cancelled} =
               SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, reason)
    end
  end

  test "owner terminalization leaves an archived event archived" do
    event = create_event()
    run = claim!(event.id)
    Repo.update_all(from(e in Event, where: e.id == ^event.id), set: [status: "archived"])

    assert {:ok, _} =
             SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :authority_revoked)

    assert Repo.get!(Event, event.id).status == "archived"
  end

  test "completed, failed, and cancelled runs never accept another owner mutation" do
    terminalizers = [
      fn event, run -> SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 1, 1) end,
      fn event, run ->
        SyncRun.fail(event.id, run.sync_run_id, run.owner_token, :worker_failed, 1)
      end,
      fn event, run ->
        SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :user_cancelled)
      end
    ]

    for terminalize <- terminalizers do
      event = create_event()
      run = claim!(event.id)
      assert {:ok, terminal} = terminalize.(event, run)

      assert {:error, :terminal_state} =
               SyncRun.renew_lease(event.id, run.sync_run_id, run.owner_token)

      assert {:error, :terminal_state} =
               SyncRun.update_progress(event.id, run.sync_run_id, run.owner_token, 2, 2, 2)

      assert {:error, :terminal_state} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)

      assert {:error, :terminal_state} =
               SyncRun.resume(event.id, run.sync_run_id, run.owner_token)

      assert {:error, :terminal_state} =
               SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 2, 2)

      assert {:error, :terminal_state} =
               SyncRun.fail(event.id, run.sync_run_id, run.owner_token, :lease_expired, 2)

      persisted = Repo.get!(SyncLog, run.id)
      assert persisted.status == terminal.status
      assert persisted.completed_at == terminal.completed_at
      assert persisted.error_message == terminal.error_message
      assert persisted.heartbeat_at == terminal.heartbeat_at
      assert persisted.lease_expires_at == terminal.lease_expires_at
    end
  end

  test "claim rolls back the inserted run if the event transition fails" do
    event = create_event()
    install_event_status_failure(event.id, "syncing")

    assert_raise Postgrex.Error, fn -> SyncRun.claim(event.id) end
    assert Repo.aggregate(SyncLog, :count) == 0
    assert Repo.get!(Event, event.id).status == "active"
  end

  test "terminalization rolls back the run update if the event transition fails" do
    event = create_event()
    run = claim!(event.id)
    install_event_status_failure(event.id, "active")

    assert_raise Postgrex.Error, fn ->
      SyncRun.complete(event.id, run.sync_run_id, run.owner_token, 0, 0)
    end

    assert Repo.get!(SyncLog, run.id).status == "in_progress"
    assert Repo.get!(Event, event.id).status == "syncing"
  end

  defp claim!(event_id) do
    assert {:ok, run} = SyncRun.claim(event_id)
    run
  end

  defp insert_legacy_run(event_id, status) do
    Repo.insert!(%SyncLog{
      event_id: event_id,
      status: status,
      started_at: DateTime.truncate(db_now(), :second),
      pages_processed: 0,
      attendees_synced: 0
    })
  end

  defp insert_owned_run(event_id, status, opts) do
    now = db_now()
    expired = Keyword.get(opts, :expired, false)
    lease = DateTime.add(now, if(expired, do: -1, else: 180), :second)

    Repo.insert!(%SyncLog{
      event_id: event_id,
      sync_run_id: Ecto.UUID.generate(),
      owner_token: Ecto.UUID.generate(),
      started_at: DateTime.truncate(now, :second),
      heartbeat_at: now,
      lease_expires_at: lease,
      status: status,
      pages_processed: 0,
      attendees_synced: 0
    })
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    DateTime.from_naive!(now, "Etc/UTC")
  end

  defp active_count(event_id) do
    Repo.aggregate(
      from(run in SyncLog, where: run.event_id == ^event_id and run.status in ^@active_statuses),
      :count
    )
  end

  defp install_event_status_failure(event_id, target_status) do
    function_name = "sync_run_test_reject_event_#{System.unique_integer([:positive])}"
    trigger_name = "sync_run_test_event_guard_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'sync run test event transition rejected';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE ON events
    FOR EACH ROW
    WHEN (OLD.id = #{event_id} AND NEW.status = '#{target_status}')
    EXECUTE FUNCTION #{function_name}()
    """)
  end
end
