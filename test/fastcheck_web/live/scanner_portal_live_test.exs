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
    test "opens on camera-first field scanner with primary search and scan block", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      assert has_element?(view, "#scanner-portal-header")
      assert has_element?(view, "#scanner-portal-check-in-type-group")
      assert has_element?(view, "#scanner-primary-search")
      assert has_element?(view, "#scanner-portal-search-form")
      assert has_element?(view, "#scanner-primary-scan-block")
      assert has_element?(view, "#scanner-portal-qr-camera")
      assert has_element?(view, "#scanner-portal-start-camera-button")
      assert has_element?(view, "#scanner-portal-stop-camera-button")

      assert has_element?(
               view,
               "#scanner-portal-start-camera-button[data-control-state=\"primary\"]"
             )

      assert has_element?(
               view,
               "#scanner-portal-stop-camera-button[disabled][data-control-state=\"disabled\"]"
             )

      assert has_element?(view, "#scanner-portal-scan-form")
      assert has_element?(view, "#scanner-ticket-code")
      assert has_element?(view, "#scanner-secondary-tools")
      assert has_element?(view, "#scanner-menu-sync-action")
      assert render(view) =~ "Camera permission needed"
      assert render(view) =~ "Enable camera to start scanning."
      refute has_element?(view, "#scanner-portal-scan-result")

      refute has_element?(view, "#scanner-tab-button-overview")
      refute has_element?(view, "#scanner-tab-button-camera")
      refute has_element?(view, "#scanner-tab-button-attendees")
      refute has_element?(view, "[data-test=\"scanner-tab-overview\"]")
      refute has_element?(view, "[data-test=\"scanner-tab-attendees\"]")
      refute has_element?(view, ".scanner-search-result")
      refute has_element?(view, "#scanner-drawer-history")
      refute has_element?(view, "#scanner-drawer-attendees")
      refute has_element?(view, "#scanner-menu-attendees")
    end

    test "manual ticket-code fallback can submit a code below the primary scanner", %{
      conn: conn,
      event: event
    } do
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
      assert render(view) =~ "Accepted"
      assert_result_before_preview(view)
    end

    test "scan result banner appears for rejected scans", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: "MISSING-001"})
      |> render_submit()

      assert has_element?(view, "#scanner-portal-scan-result")
      assert render(view) =~ "Invalid ticket"
      assert_result_before_preview(view)
    end

    test "fresh scan feedback clears by ref without clearing newer results", %{
      conn: conn,
      event: event
    } do
      attendee =
        insert_attendee(event, %{
          ticket_code: "FRESH-001",
          first_name: "Fresh",
          last_name: "Guest"
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      assert render(view) =~ "Accepted"

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: "FRESH-MISSING"})
      |> render_submit()

      assert render(view) =~ "Invalid ticket"

      send(view.pid, {:clear_scan_feedback, 1})
      assert render(view) =~ "Invalid ticket"

      send(view.pid, {:clear_scan_feedback, 2})
      refute has_element?(view, "#scanner-portal-scan-result")
    end

    test "scanner closed state is visible when event closes during a session", %{
      conn: conn,
      event: event
    } do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      event
      |> Ecto.Changeset.change(status: "archived")
      |> Repo.update!()

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: "AFTER-CLOSE"})
      |> render_submit()

      assert has_element?(view, "#scanner-portal-scan-result")
      assert render(view) =~ "Scanner closed"
      assert render(view) =~ "Event archived, scanning disabled"
    end

    test "menu drawer exposes one secondary section at a time", %{conn: conn, event: event} do
      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-menu-toggle") |> render_click()
      assert has_element?(view, "#scanner-menu-panel")

      open_portal_drawer(view, "operator")
      assert has_element?(view, "#scanner-menu-operator-form")
      refute has_element?(view, "#scanner-drawer-history")

      open_portal_drawer(view, "history")
      assert has_element?(view, "#scanner-drawer-history")
      refute has_element?(view, "#scanner-menu-operator-form")

      view |> element("#scanner-menu-toggle") |> render_click()
      refute has_element?(view, "#scanner-menu-panel")
      refute has_element?(view, "#scanner-drawer-history")
    end
  end

  describe "manual attendee actions" do
    test "checks attendee in from primary search", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "IN-001",
          first_name: "Entry",
          last_name: "Guest",
          checkins_remaining: 1,
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      assert has_element?(view, "[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      assert render(view) =~ "Check in"
      assert render(view) =~ "phx-disable-with=\"Checking in...\""

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_in_at
      assert refreshed.is_currently_inside == true
      assert has_element?(view, "[data-test=\"scan-status\"]")

      assert has_element?(
               view,
               "[data-test=\"manual-check-in-#{attendee.ticket_code}\"][disabled]"
             )

      assert render(view) =~ "Checked in"
      assert render(view) =~ "Accepted"

      send(view.pid, {:settle_search_action, attendee.ticket_code, 1})
      assert render(view) =~ "Already inside"
    end

    test "checks attendee out from primary search when exit mode is selected", %{
      conn: conn,
      event: event
    } do
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

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      assert render(view) =~ "Check out"
      assert render(view) =~ "phx-disable-with=\"Checking out...\""

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      refreshed = Repo.get!(Attendee, attendee.id)
      assert refreshed.checked_out_at
      assert refreshed.is_currently_inside == false
      assert render(view) =~ "Checked out"

      send(view.pid, {:settle_search_action, attendee.ticket_code, 1})
      assert render(view) =~ "Not inside"
    end

    test "failed manual action clears pending row state and remains actionable", %{
      conn: conn,
      event: event
    } do
      attendee =
        insert_attendee(event, %{
          ticket_code: "ROW-PAYMENT-001",
          first_name: "Payment",
          last_name: "Guest",
          payment_status: "refunded",
          checkins_remaining: 1,
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => attendee.ticket_code})

      view
      |> element("[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      |> render_click()

      assert render(view) =~ "Payment issue"
      assert render(view) =~ "Check in"
      refute render(view) =~ "Checked in"
    end

    test "renders purchaser-linked results beyond the old 3-visible-result cap", %{
      conn: conn,
      event: event
    } do
      attendees =
        for index <- 1..6 do
          insert_attendee(event, %{
            ticket_code: "GROUP-#{index}",
            first_name: "Guest#{index}",
            last_name: "Member",
            email: "guest#{index}@example.com",
            custom_fields: %{
              "buyer_first" => "Pat",
              "buyer_last" => "Johnson",
              "buyer_email" => "pat.johnson@example.com"
            }
          })
        end

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => "pat johnson"})

      assert has_element?(view, "#scanner-portal-search-results")

      Enum.each(attendees, fn attendee ->
        assert has_element?(view, "[data-test=\"manual-check-in-#{attendee.ticket_code}\"]")
      end)
    end

    test "shows the portal truncation helper only when more raw matches exist", %{
      conn: conn,
      event: event
    } do
      for index <- 1..51 do
        insert_attendee(event, %{
          ticket_code: "TRUNC-#{index}",
          first_name: "Guest#{index}",
          last_name: "Overflow",
          custom_fields: %{"buyer_email" => "overflow@example.com"}
        })
      end

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> element("#scanner-portal-search-form")
      |> render_change(%{"query" => "overflow@example.com"})

      html = render(view)
      assert html =~ "More matches exist for this search. Keep typing to narrow the list."
      assert has_element?(view, "#scanner-portal-search-results")
      assert has_element?(view, "[data-test=\"manual-check-in-TRUNC-1\"]")

      assert Regex.scan(~r/data-test="manual-check-in-TRUNC-\d+"/, html)
             |> length() == 50
    end
  end

  describe "field result states" do
    test "payment-invalid attendee shows payment issue", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "PAYMENT-001",
          payment_status: "refunded"
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      assert render(view) =~ "Payment issue"
    end

    test "already-inside attendee shows already inside", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "INSIDE-001",
          is_currently_inside: true
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      assert render(view) =~ "Already inside"
    end

    test "exhausted attendee shows no check-ins left", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "LIMIT-001",
          checkins_remaining: 0,
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      assert render(view) =~ "No check-ins left"
    end

    test "exit for attendee not inside shows not checked in", %{conn: conn, event: event} do
      attendee =
        insert_attendee(event, %{
          ticket_code: "NOT-IN-001",
          is_currently_inside: false
        })

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      view |> element("#scanner-portal-exit-mode-button") |> render_click()

      view
      |> form("#scanner-portal-scan-form", %{ticket_code: attendee.ticket_code})
      |> render_submit()

      assert render(view) =~ "Not checked in"
    end
  end

  describe "incremental sync utility" do
    test "secondary sync utility starts incremental sync and renders compact status", %{
      conn: conn,
      event: event
    } do
      event =
        event
        |> Ecto.Changeset.change(tickera_api_key_encrypted: "invalid-ciphertext")
        |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/scanner/#{event.id}")

      refute has_element?(view, "#scanner-menu-panel")
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

      assert has_element?(
               view,
               "#scanner-portal-reconnect-camera-button[data-control-state=\"primary\"]"
             )

      view
      |> element("#scanner-portal-qr-camera")
      |> render_hook("camera_runtime_sync", %{
        state: "running",
        message: "Camera running.",
        recoverable: true,
        desired_active: true
      })

      assert has_element?(
               view,
               "#scanner-portal-stop-camera-button[data-control-state=\"primary\"]"
             )

      assert has_element?(
               view,
               "#scanner-portal-start-camera-button[disabled][data-control-state=\"disabled\"]"
             )

      view
      |> element("#scanner-portal-qr-camera")
      |> render_hook("camera_runtime_sync", %{
        state: "idle",
        message: "Camera idle.",
        recoverable: true,
        desired_active: false
      })

      assert has_element?(
               view,
               "#scanner-portal-reconnect-camera-button[disabled][data-control-state=\"disabled\"]"
             )
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

  defp assert_result_before_preview(view) do
    html = render(view)
    result_index = html |> :binary.match("id=\"scanner-portal-scan-result\"") |> elem(0)
    preview_index = html |> :binary.match("id=\"scanner-portal-camera-preview-shell\"") |> elem(0)

    assert result_index < preview_index
  end
end
