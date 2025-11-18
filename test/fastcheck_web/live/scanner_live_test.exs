defmodule FastCheckWeb.ScannerLiveTest do
  use FastCheckWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @valid_event_attrs %{
    name: "Launch Week",
    api_key: "api-key",
    site_url: "https://example.com",
    status: "active",
    entrance_name: "Main Entrance"
  }

  @valid_attendee_attrs %{
    ticket_code: "CODE-123",
    first_name: "Jamie",
    last_name: "Rivera",
    email: "jamie@example.com",
    ticket_type: "VIP",
    allowed_checkins: 1,
    checkins_remaining: 1
  }

  describe "search_attendees event" do
    test "updates results with matches", %{conn: conn} do
      event = insert_event()
      attendee = insert_attendee(event, @valid_attendee_attrs)

      {:ok, view, _html} =
        live_isolated(conn, FastCheckWeb.ScannerLive,
          session: %{},
          params: %{"event_id" => Integer.to_string(event.id)}
        )

      view
      |> element("form#attendee-search-form")
      |> render_change(%{"query" => attendee.first_name})

      assert has_element?(view, "[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
    end
  end

  describe "manual_check_in event" do
    test "checks the attendee in and keeps banner logic", %{conn: conn} do
      event = insert_event(%{entrance_name: "VIP Gate"})
      attendee = insert_attendee(event, Map.put(@valid_attendee_attrs, :ticket_code, "VIP-777"))

      {:ok, view, _html} =
        live_isolated(conn, FastCheckWeb.ScannerLive,
          session: %{},
          params: %{"event_id" => Integer.to_string(event.id)}
        )

      view
      |> element("form#attendee-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_in_at

      assert has_element?(view, "[data-test=\"scan-status\"]")
    end
  end

  defp insert_event(attrs \\ %{}) do
    attrs = Map.merge(@valid_event_attrs, attrs)

    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_attendee(event, attrs) do
    attrs =
      attrs
      |> Map.put(:event_id, event.id)
      |> Map.put_new(:ticket_code, "CODE-" <> Ecto.UUID.generate())

    %Attendee{}
    |> Attendee.changeset(attrs)
    |> Repo.insert!()
  end
end
