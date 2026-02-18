defmodule FastCheck.AttendeesTest do
  use FastCheck.DataCase, async: true

  alias Cachex
  alias FastCheck.Attendees
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias Phoenix.PubSub
  alias Ecto.Adapters.SQL.Sandbox

  setup :disable_occupancy_tasks

  describe "search_event_attendees/3" do
    setup do
      event = insert_event!("Summit")
      other_event = insert_event!("Expo")

      %{event: event, other_event: other_event}
    end

    test "matches names, email, and ticket code case-insensitively", %{event: event} do
      matched =
        create_attendee(event, %{
          ticket_code: "VIP-001",
          first_name: "Alice",
          last_name: "Johnson",
          email: "alice@example.com"
        })

      _other =
        create_attendee(event, %{
          ticket_code: "GEN-002",
          first_name: "Bruno",
          last_name: "King",
          email: "bruno@example.com"
        })

      assert ids_for_search(event.id, "alice") == [matched.id]
      assert ids_for_search(event.id, "JOHNSON") == [matched.id]
      assert ids_for_search(event.id, "EXAMPLE.COM") == [matched.id]
      assert ids_for_search(event.id, "vip-001") == [matched.id]
    end

    test "scopes results to the provided event", %{event: event, other_event: other_event} do
      create_attendee(event, %{ticket_code: "VIP-123", first_name: "Caleb", last_name: "Snow"})

      create_attendee(other_event, %{
        ticket_code: "VIP-123",
        first_name: "Caleb",
        last_name: "Snow"
      })

      assert length(ids_for_search(event.id, "VIP")) == 1
    end

    test "returns empty list for nil or blank queries", %{event: event} do
      create_attendee(event, %{first_name: "Dana", last_name: "Mills", ticket_code: "CODE-9"})

      assert Attendees.search_event_attendees(event.id, nil) == []
      assert Attendees.search_event_attendees(event.id, "   ") == []
      assert length(ids_for_search(event.id, "  code-9  ")) == 1
    end
  end

  describe "check_in/4" do
    test "broadcasts stats updates when a scan completes" do
      event = insert_event!("Conference")

      attendee =
        create_attendee(event, %{
          ticket_code: "VIP-999",
          allowed_checkins: 1,
          checkins_remaining: 1
        })

      topic = "event:#{event.id}:stats"
      :ok = PubSub.subscribe(FastCheck.PubSub, topic)

      assert {:ok, %Attendee{}, "SUCCESS"} =
               Attendees.check_in(event.id, attendee.ticket_code, "Main", "Operator")

      assert_receive {:event_stats_updated, ^event.id, stats}, 250
      assert stats.checked_in == 1
      assert stats.total == 1
    end

    test "rejects invalid ticket codes" do
      event = insert_event!("Conference")

      assert {:error, "INVALID_CODE", message} =
               Attendees.check_in(event.id, "  x ", "Main", "Operator")

      assert message =~ "Ticket code"
    end

    test "rejects invalid entrance names" do
      event = insert_event!("Conference")

      assert {:error, "INVALID_CODE", message} =
               Attendees.check_in(event.id, "VALID-CODE", "<invalid>", "Operator")

      assert message =~ "Entrance name"
    end

    test "rejects non-completed order statuses with clear message" do
      event = insert_event!("Conference")

      attendee =
        create_attendee(event, %{
          ticket_code: "PAY-001",
          allowed_checkins: 1,
          checkins_remaining: 1,
          payment_status: "paid"
        })

      assert {:error, "PAYMENT_INVALID", message} =
               Attendees.check_in(event.id, attendee.ticket_code, "Main", "Operator")

      assert message =~ "not completed"
      assert message =~ "paid"
    end

    test "accepts completed status case-insensitively" do
      event = insert_event!("Conference")

      attendee =
        create_attendee(event, %{
          ticket_code: "PAY-002",
          allowed_checkins: 1,
          checkins_remaining: 1,
          payment_status: "Completed"
        })

      assert {:ok, %Attendee{}, "SUCCESS"} =
               Attendees.check_in(event.id, attendee.ticket_code, "Main", "Operator")
    end
  end

  describe "check_in_advanced/5" do
    test "prevents concurrent check-ins on the same ticket" do
      event = insert_event!("Concurrent")

      attendee =
        create_attendee(event, %{
          allowed_checkins: 1,
          checkins_remaining: 1,
          ticket_type: "VIP"
        })

      parent = self()

      attempts =
        1..2
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Sandbox.allow(FastCheck.Repo, parent, self())

            Attendees.check_in_advanced(
              event.id,
              attendee.ticket_code,
              "success",
              "North Gate",
              "Scanner"
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 1_500))

      assert Enum.count(attempts, &match?({:ok, %Attendee{}, "SUCCESS"}, &1)) == 1
      assert Enum.count(attempts, &match?({:error, "ALREADY_INSIDE", _}, &1)) == 1
    end

    test "respects allowed_checkins limit across reentries" do
      event = insert_event!("Limited")

      attendee =
        create_attendee(event, %{
          allowed_checkins: 2,
          checkins_remaining: 2
        })

      assert {:ok, %Attendee{} = first_pass, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 attendee.ticket_code,
                 "success",
                 "Main Gate",
                 "Ops"
               )

      assert first_pass.checkins_remaining == 1

      assert {:ok, _checked_out, "CHECKED_OUT"} =
               Attendees.check_out(event.id, attendee.ticket_code, "Main Gate", "Ops")

      assert {:ok, %Attendee{} = second_pass, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 attendee.ticket_code,
                 "success",
                 "Main Gate",
                 "Ops"
               )

      assert second_pass.checkins_remaining == 0

      assert {:ok, _checked_out_again, "CHECKED_OUT"} =
               Attendees.check_out(event.id, attendee.ticket_code, "Main Gate", "Ops")

      assert {:error, "LIMIT_EXCEEDED", _} =
               Attendees.check_in_advanced(
                 event.id,
                 attendee.ticket_code,
                 "success",
                 "Main Gate",
                 "Ops"
               )
    end

    test "resets daily scan counters when a new day starts" do
      event = insert_event!("Daily Window")
      yesterday = Date.add(Date.utc_today(), -1)

      attendee =
        create_attendee(event, %{
          allowed_checkins: 3,
          checkins_remaining: 3,
          daily_scan_count: 5,
          last_checked_in_date: yesterday
        })

      assert {:ok, updated, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 attendee.ticket_code,
                 "success",
                 "South Gate",
                 "Ops"
               )

      assert updated.daily_scan_count == 1
      assert updated.last_checked_in_date == Date.utc_today()
    end

    test "computes occupancy after entry and exit scans" do
      event = insert_event!("Occupancy")
      stay_inside = create_attendee(event, %{allowed_checkins: 2, checkins_remaining: 2})
      come_and_go = create_attendee(event, %{allowed_checkins: 2, checkins_remaining: 2})
      _pending_attendee = create_attendee(event, %{allowed_checkins: 2, checkins_remaining: 2})

      assert {:ok, _inside, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 stay_inside.ticket_code,
                 "entry",
                 "West Gate",
                 "Ops"
               )

      assert {:ok, _entered, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 come_and_go.ticket_code,
                 "entry",
                 "West Gate",
                 "Ops"
               )

      assert {:ok, _exited, "CHECKED_OUT"} =
               Attendees.check_out(event.id, come_and_go.ticket_code, "West Gate", "Ops")

      breakdown = Attendees.get_occupancy_breakdown(event.id)

      assert breakdown.total == 3
      assert breakdown.checked_in == 2
      assert breakdown.checked_out == 1
      assert breakdown.currently_inside == 1
      assert breakdown.pending == 1
      assert_in_delta breakdown.occupancy_percentage, 33.33, 0.1
    end

    test "caches occupancy breakdown for two seconds" do
      event = insert_event!("Cached occupancy")
      attendee = create_attendee(event, %{allowed_checkins: 1, checkins_remaining: 1})

      initial = Attendees.get_occupancy_breakdown(event.id)
      assert initial.currently_inside == 0

      cache_key = "occupancy:event:#{event.id}:breakdown"

      assert {:ok, %{} = cached} = Cachex.get(:fastcheck_cache, cache_key)
      assert cached == initial

      assert {:ok, ttl} = Cachex.ttl(:fastcheck_cache, cache_key)
      assert ttl <= 2_000
      assert ttl > 0

      assert {:ok, %Attendee{}, "SUCCESS"} =
               Attendees.check_in_advanced(
                 event.id,
                 attendee.ticket_code,
                 "entry",
                 "Main Gate",
                 nil
               )

      cached_breakdown = Attendees.get_occupancy_breakdown(event.id)
      assert cached_breakdown.currently_inside == 0

      Process.sleep(2_100)

      refreshed = Attendees.get_occupancy_breakdown(event.id)
      assert refreshed.currently_inside == 1
    end
  end

  defp ids_for_search(event_id, query) do
    event_id
    |> Attendees.search_event_attendees(query)
    |> Enum.map(& &1.id)
  end

  defp create_attendee(event, attrs) do
    defaults = %{
      event_id: event.id,
      ticket_code: unique_ticket_code(),
      first_name: "Test",
      last_name: "User",
      email: "test@example.com",
      payment_status: "completed"
    }

    attrs = Map.merge(defaults, attrs)

    %Attendee{}
    |> Attendee.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_event!(name) do
    api_key = "key-#{System.unique_integer([:positive])}"
    {:ok, encrypted} = FastCheck.Crypto.encrypt(api_key)

    %Event{}
    |> Event.changeset(%{
      name: name,
      tickera_api_key_encrypted: encrypted,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: "https://example.com"
    })
    |> Repo.insert!()
  end

  defp unique_ticket_code do
    "CODE-#{System.unique_integer([:positive])}"
  end

  defp disable_occupancy_tasks(_) do
    original = Application.get_env(:fastcheck, :disable_occupancy_tasks, false)
    Application.put_env(:fastcheck, :disable_occupancy_tasks, true)

    on_exit(fn ->
      Application.put_env(:fastcheck, :disable_occupancy_tasks, original)
    end)

    :ok
  end
end
