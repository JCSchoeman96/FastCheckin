defmodule FastCheck.Events.SyncRunHeartbeatTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Events.{SyncLog, SyncRun, SyncRunHeartbeat, SyncRunRecovery, SyncState}
  alias FastCheck.Repo

  test "renews a paused run and keeps the same durable owner" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    {:ok, paused} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    :ok = SyncState.init_sync(event.id, run.sync_run_id, run.owner_token, run.id)
    parent = self()

    {:ok, heartbeat} =
      SyncRunHeartbeat.start_link(event.id, run, fn _event_id -> :ok end,
        interval_ms: 10,
        notify: parent
      )

    assert_receive {:sync_run_heartbeat, :renewed, "paused"}, 1_000
    renewed = Repo.get!(SyncLog, paused.id)
    assert renewed.status == "paused"
    assert renewed.heartbeat_at > paused.heartbeat_at
    assert renewed.lease_expires_at > paused.lease_expires_at
    assert Repo.get!(SyncLog, run.id).sync_run_id == run.sync_run_id

    SyncRunHeartbeat.stop(heartbeat)
  end

  test "revocation cancels the exact run and clears only its matching hot state" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    {:ok, _paused} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    :ok = SyncState.init_sync(event.id, run.sync_run_id, run.owner_token, run.id)
    {:ok, other_event} = FastCheck.Events.SyncRun.claim(create_event().id)

    :ok =
      SyncState.init_sync(
        other_event.event_id,
        other_event.sync_run_id,
        other_event.owner_token,
        other_event.id
      )

    parent = self()
    guard = fn _event_id -> {:error, :revoked} end

    {:ok, heartbeat} =
      SyncRunHeartbeat.start_link(event.id, run, guard, interval_ms: 10, notify: parent)

    monitor = Process.monitor(heartbeat)
    assert_receive {:sync_run_heartbeat, :terminal, :authority_revoked}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, 1_000

    cancelled = Repo.get!(SyncLog, run.id)
    assert cancelled.status == "cancelled"
    assert cancelled.error_message == "authority_revoked"
    assert {:error, :not_found} = SyncState.get_state(event.id, run.sync_run_id, run.owner_token)

    assert {:ok, _} =
             SyncState.get_state(
               other_event.event_id,
               other_event.sync_run_id,
               other_event.owner_token
             )
  end

  test "stale, expired, and terminal owners stop without renewal" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    parent = self()

    Repo.update_all(
      from(log in SyncLog, where: log.id == ^run.id),
      set: [owner_token: Ecto.UUID.generate()]
    )

    {:ok, stale_heartbeat} =
      SyncRunHeartbeat.start_link(event.id, run, fn _event_id -> :ok end,
        interval_ms: 10,
        notify: parent
      )

    stale_monitor = Process.monitor(stale_heartbeat)
    assert_receive {:sync_run_heartbeat, :terminal, :stale_owner}, 1_000
    assert_receive {:DOWN, ^stale_monitor, :process, ^stale_heartbeat, :normal}, 1_000
    assert Repo.get!(SyncLog, run.id).heartbeat_at == run.heartbeat_at

    expired_event = create_event()
    {:ok, expired_run} = SyncRun.claim(expired_event.id)

    Repo.update_all(
      from(log in SyncLog, where: log.id == ^expired_run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    {:ok, expired_heartbeat} =
      SyncRunHeartbeat.start_link(expired_event.id, expired_run, fn _event_id -> :ok end,
        interval_ms: 10,
        notify: parent
      )

    expired_monitor = Process.monitor(expired_heartbeat)
    assert_receive {:sync_run_heartbeat, :terminal, :lease_expired}, 1_000
    assert_receive {:DOWN, ^expired_monitor, :process, ^expired_heartbeat, :normal}, 1_000

    terminal_event = create_event()
    {:ok, terminal_run} = SyncRun.claim(terminal_event.id)

    {:ok, _} =
      SyncRun.complete(
        terminal_event.id,
        terminal_run.sync_run_id,
        terminal_run.owner_token,
        0,
        0
      )

    {:ok, terminal_heartbeat} =
      SyncRunHeartbeat.start_link(terminal_event.id, terminal_run, fn _event_id -> :ok end,
        interval_ms: 10,
        notify: parent
      )

    terminal_monitor = Process.monitor(terminal_heartbeat)
    assert_receive {:sync_run_heartbeat, :terminal, :terminal_state}, 1_000
    assert_receive {:DOWN, ^terminal_monitor, :process, ^terminal_heartbeat, :normal}, 1_000
  end

  test "heartbeat is linked to and dies with its worker" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    parent = self()

    worker =
      spawn(fn ->
        {:ok, heartbeat} =
          SyncRunHeartbeat.start_link(event.id, run, fn _event_id -> :ok end,
            interval_ms: 60_000,
            notify: parent
          )

        send(parent, {:heartbeat_started, self(), heartbeat})

        receive do
          :die -> exit(:kill)
        end
      end)

    assert_receive {:heartbeat_started, ^worker, heartbeat}, 1_000
    heartbeat_monitor = Process.monitor(heartbeat)
    assert Process.alive?(heartbeat)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^heartbeat_monitor, :process, ^heartbeat, :killed}, 1_000

    Repo.update_all(
      from(log in SyncLog, where: log.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert %{recovered: 1, skipped: 0} = SyncRunRecovery.recover_expired()
    assert Repo.get!(SyncLog, run.id).status == "failed"
  end
end
