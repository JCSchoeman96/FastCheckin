defmodule FastCheck.Events.SyncRunnerTest do
  use FastCheck.DataCase, async: false
  import Ecto.Query

  import FastCheck.Fixtures

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.{Event, SyncLog, SyncRun, SyncRunner, SyncState}
  alias FastCheck.Repo
  alias Req.Response

  setup do
    prior = Application.get_env(:fastcheck, :tickera_request_fun)

    on_exit(fn ->
      if is_nil(prior),
        do: Application.delete_env(:fastcheck, :tickera_request_fun),
        else: Application.put_env(:fastcheck, :tickera_request_fun, prior)
    end)

    :ok
  end

  test "a missing guard fails closed before claim or HTTP" do
    event = create_event()
    parent = self()
    set_request_fun(fn request -> send(parent, {:request, request}) end)

    assert {:error, :authority_required} = SyncRunner.run(event.id, nil)
    assert Repo.aggregate(SyncLog, :count) == 0
    refute_received {:request, _}
  end

  test "guarded facade is additive and invalid options fail before claim" do
    event = create_event()
    parent = self()
    set_request_fun(fn request -> send(parent, {:request, request}) end)

    assert function_exported?(FastCheck.Events, :sync_event_guarded, 2)
    assert function_exported?(FastCheck.Events, :sync_event_guarded, 4)

    assert {:error, :invalid_options} =
             SyncRunner.run(event.id, fn _event_id -> :ok end, nil, max_attempts: 0)

    assert Repo.aggregate(SyncLog, :count) == 0
    refute_received {:request, _}
  end

  test "a revoked guard fails before claim or the first request" do
    event = create_event()
    parent = self()
    set_request_fun(fn request -> send(parent, {:request, request}) end)

    assert {:error, :authority_revoked} =
             SyncRunner.run(event.id, fn _event_id -> {:error, :revoked} end)

    assert Repo.aggregate(SyncLog, :count) == 0
    refute_received {:request, _}
  end

  test "authority revoked during a request discards the response and cancels the run" do
    event = create_event()
    parent = self()
    {:ok, authority} = Agent.start_link(fn -> true end)

    set_request_fun(fn _request ->
      send(parent, {:request_dispatched, self()})

      receive do
        :release_response -> {:ok, %Response{status: 200, body: %{"total_tickets" => 1}}}
      after
        2_000 -> raise "request release timed out"
      end
    end)

    guard = fn _event_id -> if Agent.get(authority, & &1), do: :ok, else: {:error, :revoked} end
    task = Task.async(fn -> SyncRunner.run(event.id, guard) end)

    assert_receive {:request_dispatched, request_pid}, 1_000
    Agent.update(authority, fn _ -> false end)
    send(request_pid, :release_response)

    assert {:error, :authority_revoked} = Task.await(task, 2_000)
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    assert run.status == "cancelled"
    assert run.error_message == "authority_revoked"
    assert Repo.aggregate(Attendee, :count, :id) == 0
  end

  test "revocation after one accepted page blocks the next page request" do
    event = create_event()
    parent = self()
    {:ok, authority} = Agent.start_link(fn -> true end)
    attendees = for n <- 1..50, do: %{"checksum" => "PAGE-#{n}"}

    set_request_fun(fn request ->
      path = request.url.path || ""
      send(parent, {:request_path, path})

      if String.contains?(path, "event_essentials") do
        {:ok, %Response{status: 200, body: %{"total_tickets" => 50}}}
      else
        {:ok, %Response{status: 200, body: %{"data" => attendees}}}
      end
    end)

    guard = fn _event_id -> if Agent.get(authority, & &1), do: :ok, else: {:error, :revoked} end
    callback = fn _page, _total, _count -> Agent.update(authority, fn _ -> false end) end

    assert {:error, :authority_revoked} = SyncRunner.run(event.id, guard, callback)
    assert_received {:request_path, essentials_path}
    assert essentials_path =~ "event_essentials"
    assert_received {:request_path, page_path}
    assert page_path =~ "tickets_info"
    refute_received {:request_path, _}
    assert Repo.aggregate(Attendee, :count, :id) == 0
  end

  test "full guarded sync uses the claimed run identity for reconciliation" do
    event = create_event(%{total_tickets: 0})
    attendee = %{"checksum" => "GUARDED-1", "buyer_first" => "Guest", "buyer_last" => "One"}

    set_request_fun(fn request ->
      path = request.url.path || ""

      cond do
        String.contains?(path, "event_essentials") ->
          {:ok, %Response{status: 200, body: %{"total_tickets" => 1}}}

        String.contains?(path, "tickets_info") ->
          {:ok, %Response{status: 200, body: %{"data" => [attendee], "additional" => %{}}}}
      end
    end)

    callback = fn page, total_pages, count ->
      assert page == 1
      assert is_nil(total_pages)
      assert count == 1
      refute Repo.in_transaction?()
      run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
      assert run.pages_processed == 1
      assert run.attendees_synced == 1

      assert {:ok, %{current_page: 1, attendees_processed: 1}} =
               SyncState.get_state(event.id, run.sync_run_id, run.owner_token)
    end

    assert {:ok, _message} = SyncRunner.run(event.id, fn _event_id -> :ok end, callback)

    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    attendee_row = Repo.one!(from row in Attendee, where: row.event_id == ^event.id)
    refreshed_event = Repo.get!(Event, event.id)

    assert run.status == "completed"
    assert run.sync_run_id == attendee_row.last_authoritative_sync_run_id
    assert attendee_row.ticket_code == "GUARDED-1"
    assert refreshed_event.status == "active"
    assert refreshed_event.last_sync_at
    assert refreshed_event.sync_completed_at
  end

  test "retryable request failure reuses the single claimed run" do
    event = create_event()
    parent = self()
    attendee = %{"checksum" => "RETRY-1"}
    Process.put(:guarded_retry_ticket_calls, 0)

    set_request_fun(fn request ->
      path = request.url.path || ""
      send(parent, {:request_path, path})

      if String.contains?(path, "event_essentials") do
        {:ok, %Response{status: 200, body: %{}}}
      else
        calls = Process.get(:guarded_retry_ticket_calls, 0) + 1
        Process.put(:guarded_retry_ticket_calls, calls)

        if calls == 1 do
          {:error, :timeout}
        else
          {:ok, %Response{status: 200, body: %{"data" => [attendee]}}}
        end
      end
    end)

    assert {:ok, _message} =
             SyncRunner.run(event.id, fn _event_id -> :ok end, nil, max_attempts: 2)

    assert Repo.aggregate(SyncLog, :count) == 1
    assert_received {:request_path, _}
    assert_received {:request_path, _}
    assert_received {:request_path, _}
    refute_received {:request_path, _}
  end

  test "incremental guarded sync completes without absence reconciliation" do
    previous_sync =
      DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:second)

    event = create_event(%{last_sync_at: previous_sync})
    attendee = %{"checksum" => "INCREMENTAL-1"}

    set_request_fun(fn request ->
      if String.contains?(request.url.path || "", "event_essentials") do
        {:ok, %Response{status: 200, body: %{}}}
      else
        {:ok, %Response{status: 200, body: %{"data" => [attendee]}}}
      end
    end)

    assert {:ok, _message} =
             SyncRunner.run(event.id, fn _event_id -> :ok end, nil, incremental: true)

    event = Repo.get!(Event, event.id)
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    attendee_row = Repo.one!(from row in Attendee, where: row.event_id == ^event.id)

    assert run.status == "completed"
    assert event.event_sync_version == 1
    assert is_nil(attendee_row.last_authoritative_sync_run_id)
  end

  test "paused run accepts its in-flight response and blocks the next request" do
    event = create_event()
    parent = self()

    set_request_fun(fn _request ->
      send(parent, {:request_dispatched, self()})

      receive do
        :release_response -> {:ok, %Response{status: 200, body: %{}}}
      after
        2_000 -> raise "request release timed out"
      end
    end)

    task = Task.async(fn -> SyncRunner.run(event.id, fn _event_id -> :ok end) end)
    assert_receive {:request_dispatched, request_pid}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    assert {:ok, paused} = SyncRun.pause(event.id, run.sync_run_id, run.owner_token)
    send(request_pid, :release_response)

    assert {:error, :paused} = Task.await(task, 2_000)
    assert Repo.get!(SyncLog, run.id).status == "paused"
    assert {:ok, resumed} = SyncRun.resume(event.id, run.sync_run_id, run.owner_token)
    assert resumed.sync_run_id == paused.sync_run_id
    assert resumed.owner_token == paused.owner_token
    assert {:ok, _state} = SyncState.get_state(event.id, run.sync_run_id, run.owner_token)
  end

  test "partial full snapshot is neither reconciled nor marked complete" do
    event = create_event(%{total_tickets: 0})
    {:ok, 1} = FastCheck.Attendees.create_bulk(event.id, [%{"checksum" => "EXISTING-1"}])
    existing = Repo.one!(from row in Attendee, where: row.event_id == ^event.id)
    attendees = for n <- 1..50, do: %{"checksum" => "PARTIAL-#{n}"}

    set_request_fun(fn request ->
      path = request.url.path || ""

      cond do
        String.contains?(path, "event_essentials") ->
          {:ok, %Response{status: 200, body: %{"total_tickets" => 51}}}

        String.contains?(path, "tickets_info/50/2") ->
          {:error, :timeout}

        true ->
          {:ok, %Response{status: 200, body: %{"data" => attendees}}}
      end
    end)

    assert {:error, :worker_failed} =
             SyncRunner.run(event.id, fn _event_id -> :ok end, nil, max_attempts: 2)

    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    existing = Repo.get!(Attendee, existing.id)

    assert run.status == "failed"
    assert run.error_message == "worker_failed"
    assert is_nil(Repo.get!(Event, event.id).sync_completed_at)
    assert existing.scan_eligibility == "active"
    assert is_nil(existing.last_authoritative_sync_run_id)

    assert Repo.aggregate(from(row in Attendee, where: row.event_id == ^event.id), :count, :id) ==
             1
  end

  defp set_request_fun(fun) do
    Application.put_env(:fastcheck, :tickera_request_fun, fn request ->
      refute Repo.in_transaction?()
      run = Repo.one!(from log in SyncLog, where: log.status == "in_progress")

      assert {:ok,
              %{sync_run_id: sync_run_id, owner_token: owner_token, sync_log_id: sync_log_id}} =
               SyncState.get_state(run.event_id, run.sync_run_id, run.owner_token)

      assert {sync_run_id, owner_token, sync_log_id} ==
               {run.sync_run_id, run.owner_token, run.id}

      case fun.(request) do
        nil ->
          {:ok, %Response{status: 500, body: "unexpected request"}}

        result ->
          result
      end
    end)
  end

  test "late response after exact run cancellation is discarded" do
    event = create_event(%{total_tickets: 0})
    parent = self()

    set_request_fun(fn _request ->
      send(parent, {:request_dispatched, self()})

      receive do
        :release_response -> {:ok, %Response{status: 200, body: %{"total_tickets" => 99}}}
      after
        2_000 -> raise "request release timed out"
      end
    end)

    task = Task.async(fn -> SyncRunner.run(event.id, fn _event_id -> :ok end) end)
    assert_receive {:request_dispatched, request_pid}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert {:ok, _cancelled} =
             SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :user_cancelled)

    send(request_pid, :release_response)

    assert {:error, :terminal_state} = Task.await(task, 2_000)
    assert Repo.get!(Event, event.id).total_tickets == 0
    assert Repo.get!(SyncLog, run.id).status == "cancelled"
    assert Repo.aggregate(Attendee, :count, :id) == 0
  end

  test "stale worker cannot overwrite or clear a newer hot mirror" do
    event = create_event(%{total_tickets: 0})
    parent = self()

    set_request_fun(fn _request ->
      send(parent, {:request_dispatched, self()})

      receive do
        :release_response -> {:ok, %Response{status: 200, body: %{"total_tickets" => 99}}}
      after
        2_000 -> raise "request release timed out"
      end
    end)

    task =
      Task.async(fn ->
        SyncRunner.run(event.id, fn _event_id -> :ok end, fn _, _, _ ->
          send(parent, :progress)
        end)
      end)

    assert_receive {:request_dispatched, request_pid}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    new_owner_token = Ecto.UUID.generate()

    Repo.update_all(
      from(log in SyncLog, where: log.id == ^run.id),
      set: [owner_token: new_owner_token]
    )

    :ok = SyncState.init_sync(event.id, run.sync_run_id, new_owner_token, run.id)
    send(request_pid, :release_response)

    assert {:error, :stale_owner} = Task.await(task, 2_000)
    assert Repo.get!(Event, event.id).total_tickets == 0

    assert {:ok, %{owner_token: ^new_owner_token}} =
             SyncState.get_state(event.id, run.sync_run_id, new_owner_token)

    refute_received :progress
    assert Repo.get!(SyncLog, run.id).pages_processed == 0
  end
end
