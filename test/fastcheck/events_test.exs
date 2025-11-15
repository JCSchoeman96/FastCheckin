defmodule FastCheck.EventsTest do
  use PetalBlueprint.DataCase, async: true

  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Attendees.Attendee
  alias PetalBlueprint.Repo

  describe "list_events/0" do
    test "returns attendee counts per event" do
      first_event = insert_event!("Summit")
      second_event = insert_event!("Expo")

      insert_attendees(first_event, 3)
      insert_attendees(second_event, 1)

      counts =
        Events.list_events()
        |> Enum.map(&{&1.id, &1.attendee_count})
        |> Map.new()

      assert counts[first_event.id] == 3
      assert counts[second_event.id] == 1
    end
  end

  defp insert_attendees(event, amount) do
    for _ <- 1..amount do
      attrs = %{
        event_id: event.id,
        ticket_code: unique_ticket_code(),
        first_name: "Attendee",
        last_name: "Example",
        email: "person-#{System.unique_integer([:positive])}@example.com"
      }

      %Attendee{}
      |> Attendee.changeset(attrs)
      |> Repo.insert!()
    end
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
