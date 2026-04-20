defmodule FastCheck.Events.SyncTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  import FastCheck.Fixtures

  alias FastCheck.Attendees.{Attendee, AttendeeInvalidationEvent, ReasonCodes}
  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Events.Sync
  alias FastCheck.Repo
  alias Req.Response

  setup do
    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:fastcheck, :tickera_request_fun)
      else
        Application.put_env(:fastcheck, :tickera_request_fun, previous_request_fun)
      end
    end)

    :ok
  end

  describe "module exports" do
    test "exports sync_event/3" do
      assert_exported(Sync, :sync_event, 3)
    end

    test "exports get_tickera_api_key/1" do
      assert_exported(Sync, :get_tickera_api_key, 1)
    end

    test "exports touch_last_sync/1" do
      assert_exported(Sync, :touch_last_sync, 1)
    end

    test "exports touch_last_soft_sync/1" do
      assert_exported(Sync, :touch_last_soft_sync, 1)
    end
  end

  describe "get_tickera_api_key/1" do
    test "returns a normalized decrypted key" do
      {:ok, encrypted} = Crypto.encrypt(" 5CC0A15C \n")
      event = %Event{id: 123, tickera_api_key_encrypted: encrypted}

      assert {:ok, "5CC0A15C"} = Sync.get_tickera_api_key(event)
    end

    test "returns error when decrypted key is blank" do
      {:ok, encrypted} = Crypto.encrypt("   ")
      event = %Event{id: 456, tickera_api_key_encrypted: encrypted}

      assert {:error, :decryption_failed} = Sync.get_tickera_api_key(event)
    end
  end

  describe "sync_event/3 refreshes total_tickets" do
    test "updates total_tickets after a successful full sync" do
      event = create_event(%{total_tickets: 10})
      mock_tickera_sync_requests(event_total: 137, attendees: [])

      assert {:ok, _message} = Events.sync_event(event.id)

      assert Repo.get!(Event, event.id).total_tickets == 137
    end

    test "does not warn when Tickera sold tickets matches fetched tickets_info rows" do
      event = create_event(%{total_tickets: 2})

      mock_tickera_sync_requests(
        event_total: 2,
        attendees: [unchanged_remote_attendee("MATCH-1"), unchanged_remote_attendee("MATCH-2")]
      )

      assert {:ok, message} = Events.sync_event(event.id)

      assert message == "Synced 2 attendees"
      refute message =~ "Warning:"
    end

    test "warns when Tickera sold tickets exceeds fetched tickets_info rows" do
      event = create_event(%{total_tickets: 2})

      mock_tickera_sync_requests(
        event_total: 2,
        attendees: [unchanged_remote_attendee("VISIBLE-1")]
      )

      assert {:ok, message} = Events.sync_event(event.id)

      assert message =~ "Synced 1 attendees"
      assert message =~ "Warning: Tickera reports 2 sold tickets"
      assert message =~ "tickets_info returned 1 rows"
      assert message =~ "1 ticket(s) may be hidden by cache or upstream ticket visibility rules"
    end

    test "updates total_tickets after incremental sync with zero attendee upserts" do
      last_sync_at = DateTime.utc_now() |> DateTime.truncate(:second)
      event = create_event(%{total_tickets: 10, last_sync_at: last_sync_at})
      existing_attendee = create_attendee(event, %{ticket_code: "UNCHANGED-1"})

      mock_tickera_sync_requests(
        event_total: 42,
        attendees: [unchanged_remote_attendee(existing_attendee.ticket_code)]
      )

      assert {:ok, message} = Events.sync_event(event.id, nil, incremental: true)
      assert message =~ "0 new/updated out of 1 total"
      assert Repo.get!(Event, event.id).total_tickets == 42
    end

    test "warns on incremental sync when Tickera sold tickets exceeds fetched tickets_info rows" do
      last_sync_at = DateTime.utc_now() |> DateTime.truncate(:second)
      event = create_event(%{total_tickets: 2, last_sync_at: last_sync_at})
      existing_attendee = create_attendee(event, %{ticket_code: "UNCHANGED-1"})

      mock_tickera_sync_requests(
        event_total: 2,
        attendees: [unchanged_remote_attendee(existing_attendee.ticket_code)]
      )

      assert {:ok, message} = Events.sync_event(event.id, nil, incremental: true)

      assert message =~ "Incremental sync: 0 new/updated out of 1 total"
      assert message =~ "Warning: Tickera reports 2 sold tickets"
      assert message =~ "tickets_info returned 1 rows"
    end

    test "does not warn when Tickera sold tickets cannot be normalized" do
      event = create_event(%{total_tickets: 10})

      mock_tickera_sync_requests(
        event_total: "unknown",
        attendees: [unchanged_remote_attendee("UNKNOWN-SOLD-1")]
      )

      assert {:ok, message} = Events.sync_event(event.id)

      assert message == "Synced 1 attendees"
      refute message =~ "Warning:"
    end

    test "leaves total_tickets untouched when sync fails" do
      event = create_event(%{total_tickets: 10})
      mock_tickera_sync_requests(event_total: 55, tickets_error: {:http_error, :timeout, "boom"})

      assert {:error, _message} = Events.sync_event(event.id)

      assert Repo.get!(Event, event.id).total_tickets == 10
    end

    test "returns an error when total_tickets persistence fails during completion" do
      event = create_event(%{total_tickets: 10})
      parent = self()

      mock_tickera_sync_requests(event_total: 55, attendees: [])

      task =
        Task.async(fn ->
          Events.sync_event(event.id, fn _page, _total_pages, _count ->
            send(parent, :sync_progress_reached)

            receive do
              :continue_sync -> :ok
            after
              1_000 -> flunk("timed out waiting to resume sync")
            end
          end)
        end)

      assert_receive :sync_progress_reached, 1_000
      Repo.delete!(Repo.get!(Event, event.id))
      send(task.pid, :continue_sync)

      assert {:error, "Failed to refresh event ticket totals"} = Task.await(task, 2_000)
      assert Repo.get(Event, event.id) == nil
    end

    test "does not issue an extra event update when total_tickets is unchanged" do
      event = create_event(%{total_tickets: 42})
      mock_tickera_sync_requests(event_total: 42, attendees: [])

      {result, event_update_count} =
        capture_event_update_queries(fn ->
          Events.sync_event(event.id)
        end)

      assert {:ok, _message} = result

      # Full sync: finalize_sync touches the event row; authoritative reconciliation bumps `event_sync_version`.
      assert event_update_count == 3
    end

    test "full sync reconciles locals missing from authoritative snapshot to not_scannable" do
      event = create_event(%{total_tickets: 2})
      _keep = create_attendee(event, %{ticket_code: "KEEP-AUTH"})
      gone = create_attendee(event, %{ticket_code: "GONE-AUTH"})

      mock_tickera_sync_requests(
        event_total: 1,
        attendees: [unchanged_remote_attendee("KEEP-AUTH")]
      )

      assert {:ok, _message} = Events.sync_event(event.id)

      assert Repo.get_by!(Attendee, event_id: event.id, ticket_code: "KEEP-AUTH").scan_eligibility ==
               "active"

      dropped = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "GONE-AUTH")
      assert dropped.scan_eligibility == "not_scannable"
      assert dropped.ineligibility_reason == ReasonCodes.source_missing_from_authoritative_sync()

      assert Repo.exists?(
               from(i in AttendeeInvalidationEvent,
                 where: i.attendee_id == ^gone.id and i.event_id == ^event.id
               )
             )
    end

    test "incremental sync does not reconcile locals missing from the remote fetch" do
      last_sync_at =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      event = create_event(%{total_tickets: 2, last_sync_at: last_sync_at})

      stale = create_attendee(event, %{ticket_code: "STALE-INCR"})

      mock_tickera_sync_requests(
        event_total: 1,
        attendees: [unchanged_remote_attendee("ONLY-REMOTE")]
      )

      assert {:ok, _message} = Events.sync_event(event.id, nil, incremental: true)

      assert Repo.get_by!(Attendee, id: stale.id).scan_eligibility == "active"
    end
  end

  describe "incremental_attendees_for_sync/3" do
    test "includes all attendees when there is no previous sync timestamp" do
      event = create_event()

      remote_attendees = [
        %{"checksum" => "EXISTING-1", "buyer_first" => "John"},
        %{"checksum" => "NEW-2", "buyer_first" => "Jane"}
      ]

      assert remote_attendees ==
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 nil
               )
    end

    test "includes existing attendee when sync-relevant fields changed remotely" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-1", payment_status: "pending"})

      remote_attendees = [
        %{
          "checksum" => "EXISTING-1",
          "buyer_first" => "John",
          "buyer_last" => "Doe",
          "payment_status" => "completed",
          "allowed_checkins" => 1,
          "custom_fields" => [["Buyer E-mail", "john.doe@example.com"]]
        }
      ]

      assert [%{"checksum" => "EXISTING-1"}] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end

    test "excludes existing attendee when sync-relevant fields are unchanged" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-2"})

      remote_attendees = [
        %{
          "checksum" => "EXISTING-2",
          "buyer_first" => "John",
          "buyer_last" => "Doe",
          "payment_status" => "completed",
          "allowed_checkins" => 1,
          "custom_fields" => [
            ["Ticket Type", "General Admission"],
            ["Buyer E-mail", "john.doe@example.com"]
          ]
        }
      ]

      assert [] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end

    test "includes new attendee not found locally" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-3"})

      remote_attendees = [
        %{
          "checksum" => "NEW-1",
          "buyer_first" => "Jane",
          "buyer_last" => "Roe",
          "payment_status" => "completed",
          "allowed_checkins" => 2,
          "custom_fields" => [
            ["Ticket Type", "VIP"],
            ["Buyer E-mail", "jane.roe@example.com"]
          ]
        }
      ]

      assert [%{"checksum" => "NEW-1"}] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end
  end

  defp mock_tickera_sync_requests(opts) do
    event_total = Keyword.fetch!(opts, :event_total)
    attendees = Keyword.get(opts, :attendees, [])
    tickets_error = Keyword.get(opts, :tickets_error)

    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""

      cond do
        String.ends_with?(path, "/event_essentials") ->
          {:ok, %Response{status: 200, body: %{"sold_tickets" => event_total, "pass" => true}}}

        String.contains?(path, "/tickets_info/") and not is_nil(tickets_error) ->
          {:error, tickets_error}

        String.contains?(path, "/tickets_info/") ->
          {:ok,
           %Response{
             status: 200,
             body: %{"data" => attendees, "additional" => %{"results_count" => length(attendees)}}
           }}

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end

  defp unchanged_remote_attendee(ticket_code) do
    %{
      "checksum" => ticket_code,
      "buyer_first" => "John",
      "buyer_last" => "Doe",
      "payment_date" => "1st Jan 2025 - 10:00 am",
      "allowed_checkins" => 1,
      "custom_fields" => [
        ["Ticket Type", "General Admission"],
        ["Buyer E-mail", "john.doe@example.com"]
      ]
    }
  end

  defp capture_event_update_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "sync-test-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, metadata, _config ->
        send(parent, {:repo_query, ref, metadata.query})
      end,
      nil
    )

    result = fun.()
    query_count = drain_event_update_queries(ref, 0)

    :telemetry.detach(handler_id)

    {result, query_count}
  end

  defp drain_event_update_queries(ref, count) do
    receive do
      {:repo_query, ^ref, query} ->
        updated_count =
          if is_binary(query) and String.starts_with?(query, "UPDATE \"events\"") do
            count + 1
          else
            count
          end

        drain_event_update_queries(ref, updated_count)
    after
      0 -> count
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
