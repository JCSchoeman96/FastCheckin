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

  describe "field scanner screen" do
    test "opens on camera-first field scanner without bottom tabs or secondary content", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      assert has_element?(view, "#scanner-portal-header")
      assert has_element?(view, "#scanner-portal-check-in-type-group")
      assert has_element?(view, "#scanner-field-camera")
      assert has_element?(view, "#scanner-portal-start-camera-button")
      assert has_element?(view, "#scanner-portal-scan-form")
      assert has_element?(view, "#scanner-ticket-code")

      refute has_element?(view, "#scanner-tab-button-overview")
      refute has_element?(view, "#scanner-tab-button-camera")
      refute has_element?(view, "#scanner-tab-button-attendees")
      refute has_element?(view, "[data-test=\"scanner-tab-overview\"]")
      refute has_element?(view, "[data-test=\"scanner-tab-attendees\"]")
      refute has_element?(view, "#scanner-portal-search-form")
      refute has_element?(view, "#scanner-drawer-history")
      refute has_element?(view, "#scanner-menu-sync-action")
    end

    test "hidden manual scan fallback can submit a code", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "WEDGE-001",
          first_name: "Keyboard",
          last_name: "Guest",
          checkins_remaining: 1,
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_in_at
      assert refreshed.is_currently_inside == true
      assert has_element?(view, "#scanner-portal-scan-result")
      assert render(view) =~ "Ticket valid"
    end

    test "scan result banner appears for rejected scans", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: "MISSING-001"})
      |> render_submit()

      assert has_element?(view, "#scanner-portal-scan-result")
      assert render(view) =~ "Not valid"
    end

    test "menu drawer exposes one secondary section at a time", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-menu-toggle") |> render_click()
      assert has_element?(view, "#scanner-menu-panel")

      open_portal_drawer(view, "sync")
      assert has_element?(view, "#scanner-drawer-sync")
      refute has_element?(view, "#scanner-drawer-attendees")

      open_portal_drawer(view, "attendees")
      assert has_element?(view, "#scanner-drawer-attendees")
      refute has_element?(view, "#scanner-drawer-sync")

      open_portal_drawer(view, "history")
      assert has_element?(view, "#scanner-drawer-history")
      refute has_element?(view, "#scanner-drawer-attendees")

      view |> element("#scanner-menu-toggle") |> render_click()
      refute has_element?(view, "#scanner-menu-panel")
      refute has_element?(view, "#scanner-drawer-history")
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

      open_portal_drawer(view, "attendees")

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
      open_portal_drawer(view, "attendees")

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
    test "sync drawer starts incremental sync and renders compact status", %{
      conn: conn,
      event: event
    } do
      event =
        event
        |> Ecto.Changeset.change(tickera_api_key_encrypted: "invalid-ciphertext")
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      refute has_element?(view, "#scanner-menu-panel")
      view |> element("#scanner-menu-toggle") |> render_click()
      assert has_element?(view, "#scanner-menu-panel")
      assert has_element?(view, "#scanner-menu-sync")

      open_portal_drawer(view, "sync")
      assert has_element?(view, "#scanner-menu-sync-action")
      view |> element("#scanner-menu-sync-action") |> render_click()
      assert has_element?(view, "#scanner-sync-status")

      send(view.pid, {:scanner_sync_progress, 1, 2, 10})
      assert has_element?(view, "#scanner-sync-status")

      send(view.pid, {:scanner_sync_complete, {:ok, "Incremental sync completed"}})
      assert has_element?(view, "#scanner-sync-status")
    end

    test "operator drawer shows and submits the operator form", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      refute has_element?(view, "#scanner-menu-operator-form")
      open_portal_drawer(view, "operator")
      assert has_element?(view, "#scanner-menu-operator-form")
      assert has_element?(view, "#scanner-menu-operator-save")

      conn =
        post(conn, ~p"/scanner/#{event.id}/operator", %{
          "operator_name" => "Gate Lead",
          "redirect_to" => ~p"/scanner/#{event.id}"
        })

      assert get_session(conn, :scanner_operator_name) == "Gate Lead"
      assert redirected_to(conn) == ~p"/scanner/#{event.id}"
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

  describe "camera recovery UI" do
    test "shows recovery actions on the camera tab", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      assert has_element?(view, "#scanner-portal-reconnect-camera-button")
      assert has_element?(view, "#scanner-portal-camera-recheck-button")
      refute has_element?(view, "#scanner-portal-camera-sync-button")
    end

    test "updates camera runtime and permission state from hook payloads", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> element("#scanner-portal-camera-permission-hook")
      |> render_hook("camera_permission_sync", %{
        status: "denied",
        message: "Camera blocked. Check browser permission.",
        remembered: true
      })

      assert render(view) =~ "Camera blocked"
      assert render(view) =~ "Camera blocked. Check browser permission."

      view
      |> element("#scanner-portal-qr-camera")
      |> render_hook("camera_runtime_sync", %{
        state: "error",
        message: "Reconnect camera.",
        recoverable: true,
        desired_active: false
      })

      html = render(view)
      assert html =~ "Reconnect camera"
      refute html =~ "Run incremental sync"
    end

    test "history drawer shows compact recent scans after scans occur", %{
      conn: conn,
      event: event
    } do
      attendee =
        insert_attendee(event, %{
          ticket_code: "HISTORY-001",
          first_name: "Recent",
          last_name: "Guest"
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      open_portal_drawer(view, "history")

      assert has_element?(view, "#scanner-portal-recent-scans")
      assert render(view) =~ "Recent Guest"
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

  defp open_portal_drawer(view, section) do
    unless has_element?(view, "#scanner-menu-panel") do
      view |> element("#scanner-menu-toggle") |> render_click()
    end

    button_id =
      case section do
        "operator" -> "scanner-menu-change-operator"
        other -> "scanner-menu-#{other}"
      end

    view |> element("##{button_id}") |> render_click()
  end
end
