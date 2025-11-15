defmodule FastCheck.AttendeesTest do
  use PetalBlueprint.DataCase, async: true

  alias FastCheck.Attendees
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias PetalBlueprint.Repo
  alias Phoenix.PubSub

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
      create_attendee(other_event, %{ticket_code: "VIP-123", first_name: "Caleb", last_name: "Snow"})

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
      :ok = PubSub.subscribe(PetalBlueprint.PubSub, topic)

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
      email: "test@example.com"
    }

    attrs = Map.merge(defaults, attrs)

    %Attendee{}
    |> Attendee.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_event!(name) do
    %Event{}
    |> Event.changeset(%{
      name: name,
      api_key: "key-#{System.unique_integer([:positive])}",
      site_url: "https://example.com"
    })
    |> Repo.insert!()
  end

  defp unique_ticket_code do
    "CODE-#{System.unique_integer([:positive])}"
  end
end
