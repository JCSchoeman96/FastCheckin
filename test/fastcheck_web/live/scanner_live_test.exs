defmodule FastCheckWeb.ScannerLiveTest do
  use FastCheckWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.CheckInSession
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @api_key "api-key"
  @valid_event_attrs %{
    name: "Launch Week",
    tickera_site_url: "https://example.com",
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
    checkins_remaining: 1,
    payment_status: "completed"
  }

  describe "search_attendees event" do
    test "updates results with matches", %{conn: conn} do
      event = insert_event()
      attendee = insert_attendee(event, @valid_attendee_attrs)

      {:ok, view, _html} = mount_scanner(conn, event)

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

      {:ok, view, _html} = mount_scanner(conn, event)

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

    test "uses exit mode to check attendee out", %{conn: conn} do
      event = insert_event(%{entrance_name: "Main Gate"})

      attendee =
        insert_attendee(event, %{
          ticket_code: "EXIT-123",
          first_name: "Sam",
          last_name: "Exit",
          checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second),
          is_currently_inside: true,
          checkins_remaining: 0
        })

      insert_active_session(attendee, event.entrance_name)

      {:ok, view, _html} = mount_scanner(conn, event)

      view
      |> element("#exit-mode-button")
      |> render_click()

      view
      |> element("form#attendee-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_out_at
      assert refreshed.is_currently_inside == false
    end
  end

  describe "metrics reconcile" do
    test "handles immediate reconcile message without rescheduling loops", %{conn: conn} do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      send(view.pid, :reconcile_scanner_metrics_now)

      assert has_element?(view, "form#attendee-search-form")
    end
  end

  defp insert_event(attrs \\ %{}) do
    attrs = Map.merge(@valid_event_attrs, attrs)
    api_key = Map.get(attrs, :tickera_api_key, @api_key)
    {:ok, encrypted} = FastCheck.Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = FastCheck.Crypto.encrypt("scanner-secret")

    params =
      attrs
      |> Map.put(:tickera_api_key_encrypted, encrypted)
      |> Map.put(:tickera_api_key_last4, String.slice(api_key, -4, 4))
      |> Map.put(:mobile_access_secret_encrypted, encrypted_secret)
      |> Map.delete(:tickera_api_key)

    %Event{}
    |> Event.changeset(params)
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

  defp insert_active_session(attendee, entrance_name) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %CheckInSession{}
    |> CheckInSession.changeset(%{
      attendee_id: attendee.id,
      event_id: attendee.event_id,
      entry_time: now,
      entrance_name: entrance_name || "Main Entrance"
    })
    |> Repo.insert!()
  end

  defp mount_scanner(conn, event) do
    conn
    |> init_test_session(%{dashboard_authenticated: true, dashboard_username: "admin"})
    |> live(~p"/scan/#{event.id}")
  end
end
