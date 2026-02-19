defmodule FastCheckWeb.ScannerPortalLiveTest do
  use FastCheckWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.CheckInSession
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @credential "scanner-password"

  setup %{conn: conn} do
    event = insert_event()

    conn =
      conn
      |> init_test_session(%{
        scanner_authenticated: true,
        scanner_event_id: event.id,
        scanner_event_name: event.name,
        scanner_operator_name: "Door Team"
      })

    %{conn: conn, event: event}
  end

  describe "scanner portal tabs" do
    test "opens on camera tab by default", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      assert has_element?(view, "[data-test=\"scanner-tab-camera\"]")
      assert has_element?(view, "#scanner-tab-button-camera")
    end

    test "switches between bottom tabs", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-tab-button-overview") |> render_click()
      assert has_element?(view, "[data-test=\"scanner-tab-overview\"]")

      view |> element("#scanner-tab-button-attendees") |> render_click()
      assert has_element?(view, "[data-test=\"scanner-tab-attendees\"]")
    end
  end

  describe "manual attendee actions" do
    test "checks attendee in from attendees tab", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "IN-001",
          first_name: "Entry",
          last_name: "Guest",
          checkins_remaining: 1,
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-tab-button-attendees") |> render_click()

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      assert has_element?(view, "[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_in_at
      assert refreshed.is_currently_inside == true
      assert has_element?(view, "[data-test=\"scan-status\"]")
    end

    test "checks attendee out when exit mode is selected", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "OUT-001",
          first_name: "Exit",
          last_name: "Guest",
          checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second),
          is_currently_inside: true,
          checkins_remaining: 0
        })

      insert_active_session(attendee, event.entrance_name)

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-portal-exit-mode-button") |> render_click()
      view |> element("#scanner-tab-button-attendees") |> render_click()

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_out_at
      assert refreshed.is_currently_inside == false
    end
  end

  describe "incremental sync menu" do
    test "sync action is hidden until burger menu opens and receives status updates", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      refute has_element?(view, "#scanner-menu-panel")
      view |> element("#scanner-menu-toggle") |> render_click()
      assert has_element?(view, "#scanner-menu-panel")
      assert has_element?(view, "#scanner-menu-sync")

      send(view.pid, {:scanner_sync_progress, 1, 2, 10})
      assert has_element?(view, "#scanner-sync-status")

      send(view.pid, {:scanner_sync_complete, {:ok, "Incremental sync completed"}})
      assert has_element?(view, "#scanner-sync-status")
    end

    test "operator change control is available in burger menu", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      refute has_element?(view, "#scanner-menu-operator-form")
      view |> element("#scanner-menu-toggle") |> render_click()
      assert has_element?(view, "#scanner-menu-change-operator")

      view |> element("#scanner-menu-change-operator") |> render_click()
      assert has_element?(view, "#scanner-menu-operator-form")
      assert has_element?(view, "#scanner-menu-operator-save")
    end
  end

  describe "metrics reconcile" do
    test "handles immediate reconcile message without rescheduling loops", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      send(view.pid, :reconcile_scanner_metrics_now)

      assert has_element?(view, "#scanner-portal")
    end
  end

  defp insert_event(attrs \\ %{}) do
    api_key = "api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt(@credential)

    default_attrs = %{
      name: "Portal Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_secret,
      status: "active",
      entrance_name: "Main Entrance"
    }

    params = Map.merge(default_attrs, attrs)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end

  defp insert_attendee(event, attrs) do
    default_attrs = %{
      event_id: event.id,
      ticket_code: "TICKET-#{System.unique_integer([:positive])}",
      first_name: "John",
      last_name: "Doe",
      email: "john@example.com",
      ticket_type: "General",
      allowed_checkins: 1,
      checkins_remaining: 1,
      payment_status: "completed"
    }

    params = Map.merge(default_attrs, attrs)

    %Attendee{}
    |> Attendee.changeset(params)
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
end
