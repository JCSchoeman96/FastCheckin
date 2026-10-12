defmodule FastCheck.Events.SyncRunRecoveryTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Events.{Event, SyncLog, SyncRun, SyncRunRecovery, SyncState}
  alias FastCheck.Repo

  setup do
    previous = Application.get_env(:fastcheck, :tickera_request_fun)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fastcheck, :tickera_request_fun),
        else: Application.put_env(:fastcheck, :tickera_request_fun, previous)
    end)

    :ok
  end

  test "expires active leases without creating runs or doing external work" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    :ok = SyncState.init_sync(event.id, run.sync_run_id, run.owner_token, run.id)
    expire(run)
    before_count = Repo.aggregate(SyncLog, :count)

    assert %{recovered: 1, skipped: 0} = SyncRunRecovery.recover_expired()

    failed = Repo.get!(SyncLog, run.id)
    assert failed.status == "failed"
    assert failed.error_message == "lease_expired"
    assert Repo.get!(Event, event.id).status == "active"
    assert Repo.aggregate(SyncLog, :count) == before_count
    assert {:error, :not_found} = SyncState.get_state(event.id, run.sync_run_id, run.owner_token)
  end

  test "does not resurrect an archived event and clears only the recovered owner's mirror" do
    archived = create_event()
    {:ok, archived_run} = SyncRun.claim(archived.id)

    Repo.update_all(from(event in Event, where: event.id == ^archived.id),
      set: [status: "archived"]
    )

    expire(archived_run)

    other = create_event()
    {:ok, other_run} = SyncRun.claim(other.id)

    :ok =
      SyncState.init_sync(other.id, other_run.sync_run_id, other_run.owner_token, other_run.id)

    expire(other_run)

    newer_event = create_event()
    {:ok, older_run} = SyncRun.claim(newer_event.id)

    :ok =
      SyncState.init_sync(
        newer_event.id,
        older_run.sync_run_id,
        older_run.owner_token,
        older_run.id
      )

    expire(older_run)
    :ok = SyncState.init_sync(newer_event.id, Ecto.UUID.generate(), Ecto.UUID.generate())

    assert %{recovered: 3, skipped: 0} = SyncRunRecovery.recover_expired()

    assert Repo.get!(Event, archived.id).status == "archived"
    assert Repo.get!(Event, other.id).status == "active"
    assert Repo.get!(SyncLog, older_run.id).status == "failed"

    assert {:error, :stale_owner} =
             SyncState.get_state(newer_event.id, older_run.sync_run_id, older_run.owner_token)

    assert %{sync_run_id: mirror_run_id} = SyncState.get_state(newer_event.id)
    refute mirror_run_id == older_run.sync_run_id
  end

  test "caps each recovery batch at one hundred rows" do
    runs =
      for _ <- 1..101 do
        event = create_event()
        {:ok, run} = SyncRun.claim(event.id)
        expire(run)
        run
      end

    assert %{recovered: 100, skipped: 0} = SyncRunRecovery.recover_expired(limit: 101)
    assert Enum.count(runs, &(Repo.get!(SyncLog, &1.id).status == "failed")) == 100
    assert Enum.count(runs, &(Repo.get!(SyncLog, &1.id).status == "in_progress")) == 1
  end

  test "skips a renewed run and a terminal run" do
    renewed_event = create_event()
    {:ok, renewed} = SyncRun.claim(renewed_event.id)

    {:ok, _renewed} =
      SyncRun.renew_lease(renewed_event.id, renewed.sync_run_id, renewed.owner_token)

    terminal_event = create_event()
    {:ok, terminal} = SyncRun.claim(terminal_event.id)

    {:ok, _completed} =
      SyncRun.complete(terminal_event.id, terminal.sync_run_id, terminal.owner_token, 0, 0)

    assert %{recovered: 0, skipped: 0} = SyncRunRecovery.recover_expired()
    assert Repo.get!(SyncLog, renewed.id).status == "in_progress"
    assert Repo.get!(SyncLog, terminal.id).status == "completed"
  end

  test "recovery performs no Tickera requests" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    expire(run)
    parent = self()

    Application.put_env(:fastcheck, :tickera_request_fun, fn request ->
      send(parent, {:tickera_request, request})
      {:error, :unexpected_request}
    end)

    assert %{recovered: 1, skipped: 0} = SyncRunRecovery.recover_expired()
    refute_received {:tickera_request, _}
  end

  test "concurrent recovery terminalizes one expired run once" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    expire(run)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:recovery_ready, self()})

          receive do
            :recover -> SyncRunRecovery.recover_expired()
          end
        end)
      end

    for task <- tasks do
      task_pid = task.pid
      assert_receive {:recovery_ready, ^task_pid}, 1_000
    end

    Enum.each(tasks, &send(&1.pid, :recover))
    results = Enum.map(tasks, &Task.await(&1, 2_000))

    assert Enum.sum(Enum.map(results, & &1.recovered)) == 1
    assert Repo.get!(SyncLog, run.id).status == "failed"
    assert Repo.get!(Event, event.id).status == "active"
  end

  test "expired renewal racing recovery cannot return the lease to active" do
    event = create_event()
    {:ok, run} = SyncRun.claim(event.id)
    expire(run)

    renewal =
      Task.async(fn -> SyncRun.renew_lease(event.id, run.sync_run_id, run.owner_token) end)

    recovery = Task.async(fn -> SyncRunRecovery.recover_expired() end)

    renewal_result = Task.await(renewal, 2_000)
    recovery_result = Task.await(recovery, 2_000)

    assert renewal_result in [{:error, :lease_expired}, {:error, :terminal_state}]
    assert recovery_result.recovered == 1
    assert Repo.get!(SyncLog, run.id).status == "failed"
    refute_received {:tickera_request, _}
  end

  defp expire(run) do
    Repo.update_all(
      from(log in SyncLog, where: log.id == ^run.id),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end
end
