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
    test "supervisor route exposes stats, search, bulk, history, and camera recovery", %{
      conn: conn
    } do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      assert has_element?(view, "#admin-scanner-root")
      assert render(view) =~ "Current occupancy"
      assert render(view) =~ "Total tickets"
      assert has_element?(view, "form#attendee-search-form")
      assert has_element?(view, "#bulk-mode-toggle")
      assert has_element?(view, "#admin-scanner-recent-scans")
      assert has_element?(view, "#reconnect-camera-scan")
      assert has_element?(view, "#camera-recheck-button")
    end

    test "preserves keyboard and manual scan fallback form", %{conn: conn} do
      event = insert_event()
      attendee = insert_attendee(event, @valid_attendee_attrs)
      {:ok, view, _html} = mount_scanner(conn, event)

      assert has_element?(view, "#scanner-form")
      assert has_element?(view, "#scanner-ticket-code")
      assert has_element?(view, "#scanner-keyboard-shortcuts")

      view
      |> form("#scanner-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_in_at
      assert has_element?(view, "[data-test=\"scan-status\"]")
    end

    test "updates results with matches", %{conn: conn} do
      event = insert_event()
      attendee = insert_attendee(event, @valid_attendee_attrs)

      {:ok, view, _html} = mount_scanner(conn, event)

      view
      |> element("form#attendee-search-form")
      |> render_change(%{"query" => attendee.first_name})

      assert has_element?(view, "[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
    end

    test "bulk scan textarea blur enables processing", %{conn: conn} do
      event = insert_event()
      attendee = insert_attendee(event, @valid_attendee_attrs)

      {:ok, view, _html} = mount_scanner(conn, event)

      view
      |> element("#bulk-mode-toggle")
      |> render_click()

      assert has_element?(view, "#process-bulk-button[disabled]")

      view
      |> element("#bulk-scan-form textarea")
      |> render_blur(%{"value" => attendee.ticket_code})

      refute has_element?(view, "#process-bulk-button[disabled]")
      assert render(view) =~ attendee.ticket_code
    end

    test "bulk scan empty submit renders an error result", %{conn: conn} do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      view
      |> element("#bulk-mode-toggle")
      |> render_click()

      view
      |> form("#bulk-scan-form", %{codes: ""})
      |> render_submit()

      assert render(view) =~ "No ticket codes provided."
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

  describe "camera recovery UI" do
    test "renders reconnect and permission re-check actions", %{conn: conn} do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      assert has_element?(view, "#reconnect-camera-scan")
      assert has_element?(view, "#camera-recheck-button")
      assert has_element?(view, "#camera-runtime-status")
      assert render(view) =~ "Camera permission needed"
      assert render(view) =~ "Enable camera to start scanning."
    end

    test "updates permission and runtime state from hook payloads", %{conn: conn} do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      view
      |> element("#camera-permission-hook")
      |> render_hook("camera_permission_sync", %{
        status: "denied",
        message: "Camera blocked. Check browser permission.",
        remembered: true
      })

      assert render(view) =~ "Camera blocked"
      assert render(view) =~ "Camera blocked. Check browser permission."

      view
      |> element("#qr-camera-scanner")
      |> render_hook("camera_runtime_sync", %{
        state: "recovering",
        message: "Reconnect camera.",
        recoverable: true,
        desired_active: true
      })

      html = render(view)
      assert html =~ "Camera reconnecting"
      assert html =~ "Reconnect camera."
    end

    test "admin scanner handles camera controls outside field mode restrictions", %{conn: conn} do
      event = insert_event()
      {:ok, view, _html} = mount_scanner(conn, event)

      # 1. Idle state
      view
      |> element("#qr-camera-scanner")
      |> render_hook("camera_runtime_sync", %{
        state: "idle",
        message: "Camera idle.",
        recoverable: true,
        desired_active: false
      })

      # Reconnect should be available (not disabled)
      assert has_element?(
               view,
               "#reconnect-camera-scan:not([disabled])"
             )

      # Start should be available
      assert has_element?(
               view,
               "#start-camera-scan:not([disabled])"
             )

      # Stop should be disabled (not running)
      assert has_element?(
               view,
               "#stop-camera-scan[disabled]"
             )

      # 2. Running state
      view
      |> element("#qr-camera-scanner")
      |> render_hook("camera_runtime_sync", %{
        state: "running",
        message: "Camera running.",
        recoverable: true,
        desired_active: true
      })

      # Reconnect should STILL be available for the admin scanner
      assert has_element?(
               view,
               "#reconnect-camera-scan:not([disabled])"
             )

      # Start should now be disabled (already running)
      assert has_element?(
               view,
               "#start-camera-scan[disabled]"
             )

      # Stop should now be available (is running)
      assert has_element?(
               view,
               "#stop-camera-scan:not([disabled])"
             )
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
