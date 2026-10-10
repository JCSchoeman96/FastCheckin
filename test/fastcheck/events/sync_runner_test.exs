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

    Code.ensure_loaded!(FastCheck.Events)
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

  test "revocation after claim but before the first request cancels the claimed run" do
    event = create_event()
    parent = self()
    set_request_fun(fn request -> send(parent, {:request, request}) end)
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    guard = fn _event_id ->
      Agent.get_and_update(checks, fn
        0 -> {:ok, 1}
        _ -> {{:error, :revoked}, 2}
      end)
    end

    assert {:error, :authority_revoked} = SyncRunner.run(event.id, guard)
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert Agent.get(checks, & &1) == 2
    assert run.status == "cancelled"
    assert run.error_message == "authority_revoked"
    assert Repo.get!(Event, event.id).status == "active"
    assert {:error, :not_found} = SyncState.get_state(event.id, run.sync_run_id, run.owner_token)
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

  test "cancellation after the event response fence prevents event essentials writes" do
    event = create_event(%{total_tickets: 0})
    parent = self()
    barrier = make_ref()

    set_request_fun(fn request ->
      send(parent, {:essentials_request, request.url.path})
      {:ok, %Response{status: 200, body: %{"total_tickets" => 99}}}
    end)

    task =
      Task.async(fn ->
        SyncRunner.run(event.id, fn _event_id -> :ok end, nil,
          before_owner_write: owner_write_barrier(barrier, parent, :event_essentials)
        )
      end)

    assert_receive {:owner_check_paused, ^barrier, worker}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert {:ok, _cancelled} =
             SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :user_cancelled)

    send(worker, {:release_owner_check, barrier})

    assert {:error, _reason} = Task.await(task, 2_000)
    assert Repo.get!(Event, event.id).total_tickets == 0
    assert Repo.get!(SyncLog, run.id).status == "cancelled"
    assert_received {:essentials_request, essentials_path}
    assert essentials_path =~ "event_essentials"
    refute_received {:essentials_request, _}
  end

  test "cancellation after the full snapshot response fence prevents attendee reconciliation" do
    event = create_event(%{total_tickets: 0})

    {:ok, 1} =
      FastCheck.Attendees.create_bulk(event.id, [%{"checksum" => "FENCED-FULL-EXISTING"}])

    existing = Repo.one!(from row in Attendee, where: row.event_id == ^event.id)
    parent = self()
    barrier = make_ref()
    attendee = %{"checksum" => "FENCED-FULL-1"}

    set_request_fun(fn request ->
      path = request.url.path || ""

      if String.contains?(path, "tickets_info/50/2"),
        do: send(parent, {:owner_response_next_page, path})

      if String.contains?(path, "event_essentials"),
        do: {:ok, %Response{status: 200, body: %{}}},
        else: {:ok, %Response{status: 200, body: %{"data" => [attendee]}}}
    end)

    task =
      Task.async(fn ->
        SyncRunner.run(event.id, fn _event_id -> :ok end, nil,
          before_owner_write: owner_write_barrier(barrier, parent, :attendee_snapshot)
        )
      end)

    assert_receive {:owner_check_paused, ^barrier, worker}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert {:ok, _cancelled} =
             SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :user_cancelled)

    send(worker, {:release_owner_check, barrier})

    assert {:error, _reason} = Task.await(task, 2_000)

    assert Repo.aggregate(from(row in Attendee, where: row.event_id == ^event.id), :count, :id) ==
             1

    existing = Repo.get!(Attendee, existing.id)
    assert existing.scan_eligibility == "active"
    assert is_nil(existing.last_authoritative_sync_run_id)
    assert Repo.get!(SyncLog, run.id).status == "cancelled"
    refute_received {:owner_response_next_page, _}
  end

  test "cancellation after the incremental response fence prevents attendee and version writes" do
    previous_sync =
      DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:second)

    event = create_event(%{last_sync_at: previous_sync, event_sync_version: 0})
    parent = self()
    barrier = make_ref()
    attendee = %{"checksum" => "FENCED-INCREMENTAL-1"}

    set_request_fun(fn request ->
      path = request.url.path || ""

      if String.contains?(path, "tickets_info/50/2"),
        do: send(parent, {:owner_response_next_page, path})

      if String.contains?(path, "event_essentials"),
        do: {:ok, %Response{status: 200, body: %{}}},
        else: {:ok, %Response{status: 200, body: %{"data" => [attendee]}}}
    end)

    task =
      Task.async(fn ->
        SyncRunner.run(event.id, fn _event_id -> :ok end, nil,
          incremental: true,
          before_owner_write: owner_write_barrier(barrier, parent, :attendee_snapshot)
        )
      end)

    assert_receive {:owner_check_paused, ^barrier, worker}, 1_000
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert {:ok, _cancelled} =
             SyncRun.cancel(event.id, run.sync_run_id, run.owner_token, :user_cancelled)

    send(worker, {:release_owner_check, barrier})

    assert {:error, _reason} = Task.await(task, 2_000)

    assert Repo.aggregate(from(row in Attendee, where: row.event_id == ^event.id), :count, :id) ==
             0

    assert Repo.get!(Event, event.id).event_sync_version == 0
    assert Repo.get!(SyncLog, run.id).status == "cancelled"
    refute_received {:owner_response_next_page, _}
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
    assert run.pages_processed == 1
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
      run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
      send(parent, {:request_path, path, run.id, run.sync_run_id, run.owner_token})

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
    assert_received {:request_path, _, first_id, first_run_id, first_token}
    assert_received {:request_path, _, second_id, second_run_id, second_token}
    assert_received {:request_path, _, third_id, third_run_id, third_token}
    assert first_id == second_id and second_id == third_id
    assert first_run_id == second_run_id and second_run_id == third_run_id
    assert first_token == second_token and second_token == third_token
    refute_received {:request_path, _, _, _, _}
  end

  test "revocation immediately before a request retry prevents retry dispatch" do
    event = create_event()
    parent = self()
    {:ok, checks} = Agent.start_link(fn -> 0 end)

    set_request_fun(fn request ->
      path = request.url.path || ""
      send(parent, {:retry_request_path, path})

      if String.contains?(path, "event_essentials") do
        {:ok, %Response{status: 200, body: %{}}}
      else
        {:error, :timeout}
      end
    end)

    guard = fn _event_id ->
      Agent.get_and_update(checks, fn count ->
        next = count + 1
        if next == 7, do: {{:error, :revoked}, next}, else: {:ok, next}
      end)
    end

    assert {:error, :authority_revoked} =
             SyncRunner.run(event.id, guard, nil, max_attempts: 2)

    assert_received {:retry_request_path, essentials_path}
    assert essentials_path =~ "event_essentials"
    assert_received {:retry_request_path, first_page_path}
    assert first_page_path =~ "tickets_info"
    refute_received {:retry_request_path, _}

    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    assert run.status == "cancelled"
    assert run.error_message == "authority_revoked"
  end

  test "multi-page success preserves the terminal page checkpoint" do
    event = create_event()
    parent = self()
    first_page = for n <- 1..50, do: %{"checksum" => "MULTI-#{n}"}

    set_request_fun(fn request ->
      path = request.url.path || ""
      send(parent, {:page_request, path})

      cond do
        String.contains?(path, "event_essentials") ->
          {:ok, %Response{status: 200, body: %{}}}

        String.contains?(path, "tickets_info/50/1") ->
          {:ok, %Response{status: 200, body: %{"data" => first_page}}}

        true ->
          {:ok, %Response{status: 200, body: %{"data" => [%{"checksum" => "MULTI-51"}]}}}
      end
    end)

    assert {:ok, _message} = SyncRunner.run(event.id, fn _event_id -> :ok end)
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)

    assert run.status == "completed"
    assert run.pages_processed == 2
    assert_received {:page_request, first}
    assert first =~ "event_essentials"
    assert_received {:page_request, second}
    assert second =~ "tickets_info/50/1"
    assert_received {:page_request, third}
    assert third =~ "tickets_info/50/2"
  end

  test "separate additional metadata does not change a full ticket page length" do
    event = create_event()
    parent = self()
    first_page = for n <- 1..50, do: %{"checksum" => "META-#{n}"}

    set_request_fun(fn request ->
      path = request.url.path || ""
      send(parent, {:metadata_page_request, path})

      cond do
        String.contains?(path, "event_essentials") ->
          {:ok, %Response{status: 200, body: %{}}}

        String.contains?(path, "tickets_info/50/1") ->
          body = Enum.map(first_page, &%{"data" => &1}) ++ [%{"additional" => %{"pages" => 2}}]
          {:ok, %Response{status: 200, body: body}}

        true ->
          {:ok, %Response{status: 200, body: [%{"data" => %{"checksum" => "META-51"}}]}}
      end
    end)

    callback = fn page, _total_pages, count -> send(parent, {:metadata_progress, page, count}) end

    assert {:ok, _message} = SyncRunner.run(event.id, fn _event_id -> :ok end, callback)

    assert_received {:metadata_page_request, path1}
    assert path1 =~ "event_essentials"
    assert_received {:metadata_page_request, path2}
    assert path2 =~ "tickets_info/50/1"
    assert_received {:metadata_progress, 1, 50}
    assert_received {:metadata_page_request, path3}
    assert path3 =~ "tickets_info/50/2"
    assert_received {:metadata_progress, 2, 51}
    run = Repo.one!(from log in SyncLog, where: log.event_id == ^event.id)
    assert run.pages_processed == 2
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
    assert run.pages_processed == 1
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

  defp owner_write_barrier(barrier, parent, target_stage) do
    fn stage ->
      if stage == target_stage do
        send(parent, {:owner_check_paused, barrier, self()})

        receive do
          {:release_owner_check, ^barrier} -> :ok
        after
          2_000 -> raise "owner check barrier release timed out"
        end
      else
        :ok
      end
    end
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
