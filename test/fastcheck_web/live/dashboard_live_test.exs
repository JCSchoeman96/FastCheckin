defmodule FastCheckWeb.DashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Events.SyncState
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheck.Sales.DashboardAccess
  alias FastCheckWeb.SalesWebFixtures, as: SalesWebFixtures
  alias Req.Response

  setup do
    _ = Cache.invalidate_events_list_cache()

    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)
    previous_default_site_url = Application.get_env(:fastcheck, :default_tickera_site_url)
    previous_dashboard_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :default_tickera_site_url, "https://voelgoed.co.za")

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:fastcheck, :tickera_request_fun)
      else
        Application.put_env(:fastcheck, :tickera_request_fun, previous_request_fun)
      end

      if is_nil(previous_default_site_url) do
        Application.delete_env(:fastcheck, :default_tickera_site_url)
      else
        Application.put_env(:fastcheck, :default_tickera_site_url, previous_default_site_url)
      end

      restore_env(:dashboard_auth, previous_dashboard_auth)
    end)

    :ok
  end

  describe "dashboard Event isolation" do
    test "mount ignores the global Events cache and exposes scoped attendee aggregates only", %{
      conn: conn
    } do
      granted_event = insert_event!(%{name: "Granted Dashboard Event", total_tickets: 7})

      ungranted_event =
        insert_event!(%{name: "Un granted Dashboard Event", total_tickets: 93})

      Fixtures.create_attendee(ungranted_event, %{
        first_name: "Un granted aggregate attendee",
        ticket_code: "UNGRANTED-AGGREGATE"
      })

      assert Enum.any?(Events.list_events(), &(&1.id == ungranted_event.id))

      {:ok, view, html} = mount_dashboard(conn, [granted_event.id])

      assert has_element?(view, "#full-sync-#{granted_event.id}")
      refute has_element?(view, "#full-sync-#{ungranted_event.id}")
      assert html =~ granted_event.name
      refute html =~ ungranted_event.name
      refute html =~ "93"
      refute html =~ "Un granted aggregate attendee"
    end

    test "both Events are visible when both have current grants", %{conn: conn} do
      event_a = insert_event!(%{name: "Granted Event A"})
      event_b = insert_event!(%{name: "Granted Event B"})

      {:ok, view, _html} = mount_dashboard(conn, [event_a.id, event_b.id])

      assert has_element?(view, "#full-sync-#{event_a.id}")
      assert has_element?(view, "#full-sync-#{event_b.id}")
    end

    test "empty grants expose no Event rows", %{conn: conn} do
      event = insert_event!(%{name: "No Grant Dashboard Event", total_tickets: 67})

      {:ok, view, html} = mount_dashboard(conn, [])

      refute has_element?(view, "#full-sync-#{event.id}")
      refute html =~ event.name
      refute html =~ "67"
    end

    test "forged reads, lifecycle actions, sync controls, and WhatsApp changes deny ungranted Event B",
         %{
           conn: conn
         } do
      granted_event = insert_event!(%{name: "Granted Event A"})
      ungranted_event = insert_event!(%{name: "Hidden Event B"})
      assert {:ok, _} = Events.enable_whatsapp_sales(ungranted_event.id)
      assert Events.get_event!(ungranted_event.id).whatsapp_sales_enabled
      _ = SyncState.init_sync(ungranted_event.id)

      test_pid = self()

      Application.put_env(:fastcheck, :tickera_request_fun, fn _req ->
        send(test_pid, :ungranted_tickera_request)
        {:ok, %Response{status: 500, body: %{"pass" => false}}}
      end)

      {:ok, view, _html} = mount_dashboard(conn, [granted_event.id])
      {:ok, dashboard_actor} = DashboardAccess.actor_for_identity("admin")
      assert DashboardAccess.allowed_event_ids(dashboard_actor) == [granted_event.id]

      render_click(view, "show_edit_form", %{"event_id" => ungranted_event.id})
      refute has_element?(view, "#edit-event-modal")

      render_click(view, "show_sync_history", %{"event_id" => ungranted_event.id})
      refute has_element?(view, "#sync-history-modal")

      render_click(view, "start_sync", %{"event_id" => ungranted_event.id})
      render_click(view, "pause_sync", %{"event_id" => ungranted_event.id})
      render_click(view, "resume_sync", %{"event_id" => ungranted_event.id})
      render_click(view, "cancel_sync", %{"event_id" => ungranted_event.id})

      render_click(view, "enable_whatsapp_sales", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).whatsapp_sales_enabled
      render_click(view, "disable_whatsapp_sales", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).whatsapp_sales_enabled

      render_click(view, "archive_event", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).status == "active"

      assert {:ok, _} = Events.archive_event(ungranted_event.id)
      render_click(view, "unarchive_event", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).status == "archived"

      render_click(view, "remove_archived_event", %{"event_id" => ungranted_event.id})
      assert %Event{} = Repo.get(Event, ungranted_event.id)

      assert SyncState.get_state(ungranted_event.id).status == :running
      refute_receive :ungranted_tickera_request, 100
      refute render(view) =~ ungranted_event.name
    end

    test "revoking a grant after mount denies an ordinary mutation", %{conn: conn} do
      event = insert_event!(%{name: "Revoked After Mount Event"})
      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      SalesWebFixtures.configure_dashboard_grants([])
      render_click(view, "archive_event", %{"event_id" => event.id})

      assert Events.get_event!(event.id).status == "active"
      refute render(view) =~ event.name
    end

    test "search after grant revocation cannot restore a stale Event", %{conn: conn} do
      granted_event = insert_event!(%{name: "Still Granted Search Event"})
      revoked_event = insert_event!(%{name: "Revoked Search Event"})
      {:ok, view, _html} = mount_dashboard(conn, [granted_event.id, revoked_event.id])

      SalesWebFixtures.configure_dashboard_grants([granted_event.id])
      render_click(view, "search_events", %{"query" => "Revoked Search Event"})

      refute has_element?(view, "#full-sync-#{revoked_event.id}")
    end

    test "stale sync messages refresh revoked Event state", %{conn: conn} do
      event = insert_event!(%{name: "Revoked Stale Sync Message Event"})
      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      assert has_element?(view, "#full-sync-#{event.id}")

      SalesWebFixtures.configure_dashboard_grants([])
      send(view.pid, {:sync_progress, make_ref(), 1, 1, 1})

      refute has_element?(view, "#full-sync-#{event.id}")
    end

    test "revoking a grant after opening edit denies the stale editing_event_id", %{
      conn: conn
    } do
      event = insert_event!(%{name: "Stale Edit Grant Event"})
      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      view |> element("#show-edit-event-#{event.id}") |> render_click()

      SalesWebFixtures.configure_dashboard_grants([])

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => "Forged stale update",
          "tickera_site_url" => event.tickera_site_url,
          "mobile_access_code" => "",
          "location" => event.location || "",
          "entrance_name" => event.entrance_name || ""
        }
      })
      |> render_submit()

      assert Events.get_event!(event.id).name == event.name
      refute has_element?(view, "#edit-event-form")
      refute render(view) =~ event.name
    end

    test "grant revocation during a sync prevents the worker from starting a retry", %{
      conn: conn
    } do
      event = insert_event!(%{name: "Revoked During Sync Event"})
      test_pid = self()

      mock_tickera_requests(
        %{
          "event_name" => "Revoked During Sync Event",
          "event_date_time" => "2026-02-20T20:00:00Z",
          "event_location" => "Test Venue",
          "sold_tickets" => 20,
          "checked_tickets" => 0,
          "pass" => true
        },
        ticket_request_fun: fn path ->
          send(test_pid, {:tickera_sync_request, path})
          send(test_pid, {:blocked_sync_request, self()})

          receive do
            :release_sync_request ->
              {:ok, %Response{status: 500, body: %{"pass" => false}}}
          after
            5_000 ->
              {:ok, %Response{status: 500, body: %{"pass" => false}}}
          end
        end
      )

      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      view |> element("#full-sync-#{event.id}") |> render_click()

      assert_receive {:tickera_sync_request, _path}, 1_000
      assert_receive {:blocked_sync_request, request_pid}, 1_000

      SalesWebFixtures.configure_dashboard_grants([])
      send(request_pid, :release_sync_request)

      refute_receive {:tickera_sync_request, _path}, 500
      refute render(view) =~ event.name
    end
  end

  describe "edit event modal WhatsApp sales" do
    test "edit modal toggles WhatsApp sales without closing and uses distinct control ids", %{
      conn: conn
    } do
      event = insert_event!(%{name: "Edit Modal WhatsApp Gate"})

      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      view |> element("#show-edit-event-#{event.id}") |> render_click()

      assert has_element?(view, "#edit-event-modal")
      assert has_element?(view, "#edit-whatsapp-sales-section-#{event.id}")

      assert has_element?(
               view,
               "#edit-whatsapp-sales-section-#{event.id}",
               "Ticket Sales / WhatsApp Sales"
             )

      assert has_element?(view, "#edit-whatsapp-sales-section-#{event.id}", "Disabled")
      assert has_element?(view, "#edit-enable-whatsapp-sales-#{event.id}", "Enable")
      refute has_element?(view, "#edit-disable-whatsapp-sales-#{event.id}")
      refute has_element?(view, "#edit-event-form input[name='event[whatsapp_sales_enabled]']")

      view |> element("#edit-enable-whatsapp-sales-#{event.id}") |> render_click()

      assert has_element?(view, "#edit-event-modal")
      assert has_element?(view, "#edit-whatsapp-sales-section-#{event.id}", "Enabled")
      assert has_element?(view, "#edit-disable-whatsapp-sales-#{event.id}", "Disable")
      refute has_element?(view, "#edit-enable-whatsapp-sales-#{event.id}")
      assert Events.get_event!(event.id).whatsapp_sales_enabled
      assert has_element?(view, "#disable-whatsapp-sales-#{event.id}")
      assert has_element?(view, "#edit-disable-whatsapp-sales-#{event.id}")
      refute has_element?(view, "#edit-enable-whatsapp-sales-#{event.id}")

      view |> element("#edit-disable-whatsapp-sales-#{event.id}") |> render_click()

      assert has_element?(view, "#edit-event-modal")
      assert has_element?(view, "#edit-whatsapp-sales-section-#{event.id}", "Disabled")
      assert has_element?(view, "#edit-enable-whatsapp-sales-#{event.id}", "Enable")
      refute Events.get_event!(event.id).whatsapp_sales_enabled
    end

    test "ordinary update_event submission does not change WhatsApp sales gate", %{conn: conn} do
      event = insert_event!(%{name: "Gate Stable On Edit"})
      assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#show-edit-event-#{event.id}") |> render_click()

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => "Gate Stable On Edit Renamed",
          "shortname" => "",
          "tickera_site_url" => event.tickera_site_url,
          "mobile_access_code" => "",
          "location" => event.location || "",
          "entrance_name" => event.entrance_name || ""
        }
      })
      |> render_submit()

      assert Events.get_event!(event.id).whatsapp_sales_enabled
      assert Events.get_event!(event.id).name == "Gate Stable On Edit Renamed"
    end
  end

  describe "edit event modal" do
    test "operator can set an event to turnstile admission", %{conn: conn} do
      event = insert_event!(%{name: "Turnstile Dashboard Event"})

      {:ok, view, _html} = mount_dashboard(conn)
      view |> element("#show-edit-event-#{event.id}") |> render_click()

      assert has_element?(view, "select[name='event[admission_mode]']")

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => event.name,
          "tickera_site_url" => event.tickera_site_url,
          "mobile_access_code" => "",
          "location" => event.location || "",
          "entrance_name" => event.entrance_name || "",
          "admission_mode" => "turnstile"
        }
      })
      |> render_submit()

      assert Events.get_event!(event.id).admission_mode == "turnstile"
    end

    test "opens edit modal with existing values prefilled", %{conn: conn} do
      event =
        insert_event!(%{
          name: "Modal Smoke Event",
          tickera_site_url: "https://prefill.example.com",
          location: "Prefill Venue",
          entrance_name: "North Gate"
        })

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#show-edit-event-#{event.id}")

      view
      |> element("#show-edit-event-#{event.id}")
      |> render_click()

      assert has_element?(view, "#edit-event-form")
      assert has_element?(view, "#edit-event-new-api-key")

      name_input_html =
        view |> element("input[name='event[name]'][form='edit-event-form']") |> render()

      site_url_input_html =
        view
        |> element("input[name='event[tickera_site_url]'][form='edit-event-form']")
        |> render()

      location_input_html =
        view
        |> element("input[name='event[location]'][form='edit-event-form']")
        |> render()

      entrance_input_html =
        view
        |> element("input[name='event[entrance_name]'][form='edit-event-form']")
        |> render()

      assert name_input_html =~ ~s(value="Modal Smoke Event")
      assert site_url_input_html =~ ~s(value="https://prefill.example.com")
      assert location_input_html =~ ~s(value="Prefill Venue")
      assert entrance_input_html =~ ~s(value="North Gate")
    end

    test "submitting edit form with blank API key keeps existing API key", %{conn: conn} do
      event =
        insert_event!(%{
          name: "Original Event",
          tickera_site_url: "https://old.example.com",
          entrance_name: "Old Gate",
          location: "Old Venue"
        })

      old_api_key_encrypted = event.tickera_api_key_encrypted
      old_mobile_secret_encrypted = event.mobile_access_secret_encrypted

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#show-edit-event-#{event.id}")

      view
      |> element("#show-edit-event-#{event.id}")
      |> render_click()

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => "Updated Event",
          "tickera_site_url" => "https://updated.example.com",
          "tickera_api_key_encrypted" => "",
          "location" => "Updated Venue",
          "entrance_name" => "Updated Gate",
          "mobile_access_code" => ""
        }
      })
      |> render_submit()

      updated = Events.get_event!(event.id)

      assert updated.name == "Updated Event"
      assert updated.tickera_site_url == "https://updated.example.com"
      assert updated.location == "Updated Venue"
      assert updated.entrance_name == "Updated Gate"
      assert updated.tickera_api_key_encrypted == old_api_key_encrypted
      assert updated.mobile_access_secret_encrypted == old_mobile_secret_encrypted
      refute has_element?(view, "#edit-event-form")
    end

    test "submitting edit form with mobile access code rotates scanner credential", %{conn: conn} do
      event = insert_event!(%{name: "Scanner Secret Event"})

      assert :ok = Events.verify_mobile_access_secret(event, "old-scanner-secret")

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#show-edit-event-#{event.id}")

      view
      |> element("#show-edit-event-#{event.id}")
      |> render_click()

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => "Scanner Secret Event Updated",
          "tickera_site_url" => event.tickera_site_url,
          "tickera_api_key_encrypted" => "",
          "location" => event.location || "Venue",
          "entrance_name" => event.entrance_name || "Main Gate",
          "mobile_access_code" => "new-scanner-secret"
        }
      })
      |> render_submit()

      updated = Events.get_event!(event.id)

      assert :ok = Events.verify_mobile_access_secret(updated, "new-scanner-secret")

      assert {:error, :invalid_credential} =
               Events.verify_mobile_access_secret(updated, "old-scanner-secret")

      refute has_element?(view, "#edit-event-form")
    end

    test "edit modal groups settings into General, Scanning, sales, and Integrations sections", %{
      conn: conn
    } do
      event = insert_event!(%{name: "Section Layout Event"})
      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      view |> element("#show-edit-event-#{event.id}") |> render_click()

      assert has_element?(view, "#edit-event-section-general", "General")
      assert has_element?(view, "#edit-event-section-scanning", "Scanning")
      assert has_element?(view, "#edit-whatsapp-sales-section-#{event.id}", "Ticket Sales")
      assert has_element?(view, "#edit-event-section-integrations", "Integrations")
    end

    test "edit modal uses scanner password terminology and login identifier copy", %{conn: conn} do
      event = insert_event!(%{name: "Scanner Copy Event"})
      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#show-edit-event-#{event.id}") |> render_click()

      html = render(view)
      assert html =~ "Scanner password"
      assert html =~ "New scanner password"
      refute html =~ "Mobile access code"
      assert has_element?(view, "#edit-event-scanner-password-help", "scanner password")
      refute has_element?(view, "#edit-event-scanner-password-help", "scanner login code")
      assert has_element?(view, "#edit-event-scan-event-id", "Event ID")
      assert has_element?(view, "#edit-event-scan-scanner-code", "Scanner code")
      assert has_element?(view, "#edit-event-scan-login-help", "numeric Event ID")
      refute has_element?(view, "#edit-event-form input[name='event[scanner_login_code]']")
    end

    test "generic dashboard update ignores injected scanner_login_code", %{conn: conn} do
      event = insert_event!(%{name: "Scanner Code Immutable"})
      original_code = event.scanner_login_code
      assert is_binary(original_code)

      alternate_code =
        if original_code == "ABCDEF" do
          "ABCDEG"
        else
          "ABCDEF"
        end

      {:ok, view, _html} = mount_dashboard(conn)
      view |> element("#show-edit-event-#{event.id}") |> render_click()

      render_submit(view, "update_event", %{
        "event" => %{
          "name" => event.name,
          "tickera_site_url" => event.tickera_site_url,
          "tickera_api_key_encrypted" => "",
          "location" => event.location || "",
          "entrance_name" => event.entrance_name || "Main Gate",
          "mobile_access_code" => "",
          "scanner_login_code" => alternate_code
        }
      })

      assert Events.get_event!(event.id).scanner_login_code == original_code
    end

    test "edit modal keeps shortname editable", %{conn: conn} do
      event = insert_event!(%{name: "Shortname Event", shortname: "short-old"})
      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#show-edit-event-#{event.id}") |> render_click()
      assert has_element?(view, "input[name='event[shortname]'][form='edit-event-form']")

      view
      |> form("#edit-event-form", %{
        "event" => %{
          "name" => event.name,
          "shortname" => "short-new",
          "tickera_site_url" => event.tickera_site_url,
          "tickera_api_key_encrypted" => "",
          "location" => event.location || "",
          "entrance_name" => event.entrance_name || "Main Gate",
          "mobile_access_code" => ""
        }
      })
      |> render_submit()

      assert Events.get_event!(event.id).shortname == "short-new"
    end

    test "edit modal integrations show Tickera URL and masked API key only", %{conn: conn} do
      event =
        insert_event!(%{
          name: "Integrations Event",
          tickera_site_url: "https://integrations.example.com",
          tickera_api_key_last4: "1234"
        })

      {:ok, view, _html} = mount_dashboard(conn)
      view |> element("#show-edit-event-#{event.id}") |> render_click()

      assert has_element?(
               view,
               "#edit-event-section-integrations input[name='event[tickera_site_url]']"
             )

      last4_html =
        view
        |> element("#edit-event-section-integrations input[name='event[tickera_api_key_last4]']")
        |> render()

      assert last4_html =~ ~s(value="1234")
      refute render(view) =~ "live-api-key"
      assert has_element?(view, "#edit-event-new-api-key")
    end

    test "edit modal links to WhatsApp offer management", %{conn: conn} do
      event = insert_event!(%{name: "Offers Link Event"})
      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      view |> element("#show-edit-event-#{event.id}") |> render_click()

      assert has_element?(
               view,
               "#edit-manage-whatsapp-offers-#{event.id}[href='/dashboard/events/#{event.id}/whatsapp-offers']"
             )

      refute has_element?(view, "#edit-manage-whatsapp-offers-#{event.id} button")
    end
  end

  describe "sync history modal" do
    test "opens sync history modal even when no sync logs exist", %{conn: conn} do
      event = insert_event!(%{name: "No Logs Event"})

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#show-sync-history-#{event.id}")

      view
      |> element("#show-sync-history-#{event.id}")
      |> render_click()

      assert has_element?(view, "#sync-history-modal")
      assert render(view) =~ "No sync history available for this event."
    end
  end

  describe "event card actions" do
    test "renders stable action labels without pending placeholder text", %{conn: conn} do
      event = insert_event!(%{name: "Actions Event"})

      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      assert has_element?(view, "#open-scanner-#{event.id}", "Scanner")
      assert has_element?(view, "#show-sync-history-#{event.id}", "History")
      assert has_element?(view, "#show-edit-event-#{event.id}", "Edit")
      assert has_element?(view, "#export-attendees-#{event.id}", "Export attendees")
      assert has_element?(view, "#export-checkins-#{event.id}", "Export check-ins")
      assert has_element?(view, "#event-overview-#{event.id}", "Event overview")
      assert render(view) =~ "/dashboard/events/#{event.id}/overview"
      refute has_element?(view, "#open-scanner-#{event.id}", "Opening...")
      refute has_element?(view, "#show-sync-history-#{event.id}", "Opening...")
      refute has_element?(view, "#show-edit-event-#{event.id}", "Opening...")
      refute has_element?(view, "#export-attendees-#{event.id}", "Preparing...")
      refute has_element?(view, "#export-checkins-#{event.id}", "Preparing...")
    end

    test "operator can enable and disable WhatsApp Sales for an event", %{conn: conn} do
      event = insert_event!(%{name: "WhatsApp Gate Event"})

      {:ok, view, html} = mount_dashboard(conn, [event.id])

      assert html =~ "WhatsApp Sales:"
      assert has_element?(view, "#whatsapp-sales-control-#{event.id}", "Disabled")
      assert has_element?(view, "#enable-whatsapp-sales-#{event.id}", "Enable")
      refute has_element?(view, "#disable-whatsapp-sales-#{event.id}")

      view
      |> element("#enable-whatsapp-sales-#{event.id}")
      |> render_click()

      assert has_element?(view, "#whatsapp-sales-control-#{event.id}", "Enabled")
      assert has_element?(view, "#disable-whatsapp-sales-#{event.id}", "Disable")
      refute has_element?(view, "#enable-whatsapp-sales-#{event.id}")
      assert Events.get_event!(event.id).whatsapp_sales_enabled

      view
      |> element("#disable-whatsapp-sales-#{event.id}")
      |> render_click()

      assert has_element?(view, "#whatsapp-sales-control-#{event.id}", "Disabled")
      assert has_element?(view, "#enable-whatsapp-sales-#{event.id}", "Enable")
      refute Events.get_event!(event.id).whatsapp_sales_enabled
    end

    test "Sales controls are hidden and reject actions for an ungranted event", %{conn: conn} do
      granted_event = insert_event!(%{name: "Granted Sales Event"})
      ungranted_event = insert_event!(%{name: "Un granted Sales Event"})
      assert {:ok, _} = Events.enable_whatsapp_sales(ungranted_event.id)

      {:ok, view, _html} = mount_dashboard(conn, [granted_event.id])

      assert has_element?(view, "#whatsapp-sales-control-#{granted_event.id}")
      refute has_element?(view, "#whatsapp-sales-control-#{ungranted_event.id}")

      render_click(view, "disable_whatsapp_sales", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).whatsapp_sales_enabled

      render_click(view, "enable_whatsapp_sales", %{"event_id" => ungranted_event.id})
      assert Events.get_event!(ungranted_event.id).whatsapp_sales_enabled

      render_click(view, "show_edit_form", %{"event_id" => ungranted_event.id})
      refute has_element?(view, "#edit-whatsapp-sales-section-#{ungranted_event.id}")
    end
  end

  describe "archived event permanent removal" do
    test "archived empty event shows Remove permanently and removes card", %{conn: conn} do
      event = insert_event!(%{name: "Removable Archived"})
      assert {:ok, _} = Events.archive_event(event.id)

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#events-tab-archived") |> render_click()

      assert has_element?(view, "#remove-archived-event-#{event.id}", "Remove permanently")

      view
      |> element("#remove-archived-event-#{event.id}")
      |> render_click()

      html = render(view)
      assert html =~ "Archived event removed permanently."
      refute html =~ "Removable Archived"
      assert Repo.get(Event, event.id) == nil
    end

    test "active events do not show Remove permanently", %{conn: conn} do
      event = insert_event!(%{name: "Active No Remove"})

      {:ok, view, _html} = mount_dashboard(conn)

      refute has_element?(view, "#remove-archived-event-#{event.id}")
    end

    test "forged remove_archived_event on active event is rejected server-side", %{conn: conn} do
      event = insert_event!(%{name: "Forged Active Remove"})

      {:ok, view, _html} = mount_dashboard(conn)

      render_click(view, "remove_archived_event", %{"event_id" => "#{event.id}"})

      assert render(view) =~ "Only archived events can be removed."
      assert Repo.get!(Event, event.id)
    end

    test "blocked archived event stays visible with understandable copy", %{conn: conn} do
      event = insert_event!(%{name: "Blocked Archived"})
      _attendee = FastCheck.Fixtures.create_attendee(event)
      assert {:ok, _} = Events.archive_event(event.id)

      {:ok, view, _html} = mount_dashboard(conn)
      view |> element("#events-tab-archived") |> render_click()

      view
      |> element("#remove-archived-event-#{event.id}")
      |> render_click()

      html = render(view)
      assert html =~ "Cannot remove this event because related data exists:"
      assert html =~ "attendees"
      refute html =~ "john.doe@example.com"
      assert has_element?(view, "#remove-archived-event-#{event.id}")
    end

    test "unarchive event still works alongside removal control", %{conn: conn} do
      event = insert_event!(%{name: "Unarchive Still Works"})
      assert {:ok, _} = Events.archive_event(event.id)

      {:ok, view, _html} = mount_dashboard(conn)
      view |> element("#events-tab-archived") |> render_click()

      view |> element("#unarchive-event-#{event.id}") |> render_click()

      assert render(view) =~ "Event unarchived successfully"
      assert Events.get_event!(event.id).status == "active"
    end
  end

  describe "WhatsApp sales gate on dashboard" do
    test "archived events never show an enable WhatsApp Sales action", %{conn: conn} do
      event = insert_event!(%{name: "Archived WhatsApp Gate Event"})
      assert {:ok, _event} = Events.enable_whatsapp_sales(event.id)
      assert {:ok, _event} = Events.archive_event(event.id)

      {:ok, view, _html} = mount_dashboard(conn, [event.id])

      view
      |> element("#events-tab-archived")
      |> render_click()

      assert has_element?(view, "#whatsapp-sales-control-#{event.id}", "Disabled")
      refute has_element?(view, "#enable-whatsapp-sales-#{event.id}")
      refute Events.get_event!(event.id).whatsapp_sales_enabled
    end
  end

  describe "event card sync totals" do
    test "full sync refreshes Tickets on the dashboard without changing Total semantics", %{
      conn: conn
    } do
      event = insert_event!(%{name: "Tickets Refresh Event", total_tickets: 10})

      mock_tickera_requests(
        %{
          "event_name" => event.name,
          "event_location" => event.location,
          "sold_tickets" => 137,
          "checked_tickets" => 0,
          "pass" => true
        },
        ticket_delay_ms: 0
      )

      {:ok, view, _html} = mount_dashboard(conn)

      view
      |> element("#full-sync-#{event.id}")
      |> render_click()

      assert_sync_finishes(view)

      refreshed_event = Events.get_event!(event.id)

      assert refreshed_event.total_tickets == 137

      listed_event =
        Events.list_events()
        |> Enum.find(&(&1.id == event.id))

      assert listed_event.attendee_count == 0

      html = render(view)
      assert html =~ event.name
      assert html =~ "137"
      assert html =~ "Warning: Tickera reports 137 sold tickets"
      assert html =~ "tickets_info returned 0 rows"
    end

    test "cancelling an in-flight sync leaves Tickets unchanged", %{conn: conn} do
      event = insert_event!(%{name: "Tickets Cancel Event", total_tickets: 10})

      mock_tickera_requests(
        %{
          "event_name" => event.name,
          "event_location" => event.location,
          "sold_tickets" => 88,
          "checked_tickets" => 0,
          "pass" => true
        },
        ticket_delay_ms: 1_000
      )

      {:ok, view, _html} = mount_dashboard(conn)

      view
      |> element("#full-sync-#{event.id}")
      |> render_click()

      assert render(view) =~ "Starting full attendee sync"

      view
      |> element("#cancel-sync-#{event.id}")
      |> render_click()

      assert render(view) =~ "Sync cancelled"
      assert Repo.get!(Event, event.id).total_tickets == 10
    end
  end

  describe "create event flow" do
    test "create form is minimal by default and pre-fills Tickera site URL", %{conn: conn} do
      configure_dashboard_creation(true)
      {:ok, view, _html} = mount_dashboard(conn)

      view
      |> element("#show-new-event-form-button")
      |> render_click()

      assert has_element?(
               view,
               "#create-event-form input[name='event[tickera_api_key_encrypted]']"
             )

      assert has_element?(view, "#create-event-form input[name='event[mobile_access_code]']")
      refute has_element?(view, "#create-event-form input[name='event[name]']")
      assert has_element?(view, "#create-event-advanced")
      refute has_element?(view, "#create-event-advanced[open]")

      refute has_element?(view, "#create-event-enable-whatsapp-sales")

      html = render(view)
      refute html =~ "Enable WhatsApp sales for this event"

      site_url_input_html =
        view
        |> element("#create-event-form input[name='event[tickera_site_url]']")
        |> render()

      assert site_url_input_html =~ ~s(value="https://voelgoed.co.za")

      assert html =~ "numeric Event ID"
      refute html =~ "6-character event code"
    end

    test "successful creation stays pending grant and does not auto-sync", %{conn: conn} do
      configure_dashboard_creation(true)
      test_pid = self()

      mock_tickera_requests(
        %{
          "event_name" => "Auto Sync Event",
          "event_date_time" => "2026-02-19T19:00:00Z",
          "event_location" => "Auto Venue",
          "sold_tickets" => 75,
          "checked_tickets" => 3,
          "pass" => true
        },
        on_request: fn path ->
          if String.contains?(path, "tickets_info"), do: send(test_pid, :create_started_sync)
        end
      )

      {:ok, view, _html} = mount_dashboard(conn, [])

      view
      |> element("#show-new-event-form-button")
      |> render_click()

      view
      |> form("#create-event-form", %{
        "event" => %{
          "tickera_api_key_encrypted" => "live-api-key-12345",
          "mobile_access_code" => "door-secret",
          "tickera_site_url" => "https://voelgoed.co.za",
          "location" => "",
          "entrance_name" => ""
        }
      })
      |> render_submit()

      created = Repo.get_by!(Event, name: "Auto Sync Event")

      assert %Event{} = created
      assert created.entrance_name == "Main Gate"

      html = render(view)

      assert html =~ "CREATED_PENDING_SERVER_GRANT"
      assert html =~ "#{created.id}"
      refute html =~ "Starting full attendee sync"
      refute has_element?(view, "#full-sync-#{created.id}")
      refute has_element?(view, "#create-event-form")
      refute Events.get_event!(created.id).whatsapp_sales_enabled
      {:ok, actor} = DashboardAccess.actor_for_identity("admin")
      refute created.id in DashboardAccess.allowed_event_ids(actor)
      refute_receive :create_started_sync, 100
    end

    test "forged create payload cannot enable WhatsApp sales", %{
      conn: conn
    } do
      configure_dashboard_creation(true)
      test_pid = self()

      mock_tickera_requests(
        %{
          "event_name" => "WhatsApp Enabled Create Event",
          "event_date_time" => "2026-02-19T19:00:00Z",
          "event_location" => "Gate Venue",
          "sold_tickets" => 12,
          "checked_tickets" => 0,
          "pass" => true
        },
        on_request: fn path ->
          if String.contains?(path, "tickets_info"), do: send(test_pid, :create_started_sync)
        end
      )

      {:ok, view, _html} = mount_dashboard(conn, [])

      view
      |> element("#show-new-event-form-button")
      |> render_click()

      refute has_element?(view, "#create-event-enable-whatsapp-sales")

      render_click(view, "create_event", %{
        "event" => %{
          "tickera_api_key_encrypted" => "live-api-key-whatsapp",
          "mobile_access_code" => "door-secret-wa",
          "tickera_site_url" => "https://voelgoed.co.za",
          "location" => "",
          "entrance_name" => "",
          "enable_whatsapp_sales" => "true"
        }
      })

      created =
        Events.list_events()
        |> Enum.find(&(&1.name == "WhatsApp Enabled Create Event"))

      assert %Event{} = created
      refute Events.get_event!(created.id).whatsapp_sales_enabled
      assert render(view) =~ "CREATED_PENDING_SERVER_GRANT"
      refute has_element?(view, "#full-sync-#{created.id}")
      refute_receive :create_started_sync, 100
    end

    test "creation disabled by server configuration creates no Event row", %{conn: conn} do
      configure_dashboard_creation(false)
      test_pid = self()

      Application.put_env(:fastcheck, :tickera_request_fun, fn _req ->
        send(test_pid, :disabled_create_tickera_request)
        {:ok, %Response{status: 500, body: %{"pass" => false}}}
      end)

      {:ok, view, _html} = mount_dashboard(conn, [])

      render_click(view, "create_event", %{
        "event" => %{
          "name" => "Disabled Event Must Not Exist",
          "tickera_api_key_encrypted" => "key",
          "mobile_access_code" => "door-secret",
          "tickera_site_url" => "https://voelgoed.co.za"
        }
      })

      assert Repo.get_by(Event, name: "Disabled Event Must Not Exist") == nil
      assert render(view) =~ "Event creation is disabled"
      refute_receive :disabled_create_tickera_request, 100
    end

    test "failed create keeps the form open without creation-only WhatsApp controls", %{
      conn: conn
    } do
      configure_dashboard_creation(true)

      Application.put_env(:fastcheck, :tickera_request_fun, fn _req ->
        {:ok, %Response{status: 200, body: %{"pass" => false}}}
      end)

      {:ok, view, _html} = mount_dashboard(conn)

      view
      |> element("#show-new-event-form-button")
      |> render_click()

      view
      |> form("#create-event-form", %{
        "event" => %{
          "tickera_api_key_encrypted" => "bad-key",
          "mobile_access_code" => "door-secret",
          "tickera_site_url" => "https://voelgoed.co.za"
        }
      })
      |> render_submit()

      assert render(view) =~ "Unable to create event"
      assert has_element?(view, "#create-event-form")
      refute has_element?(view, "#create-event-enable-whatsapp-sales")
    end

    test "creation does not start another sync while an existing sync is running", %{conn: conn} do
      configure_dashboard_creation(true)
      existing_event = insert_event!(%{name: "Running Sync Event"})

      mock_tickera_requests(
        %{
          "event_name" => "Second Event",
          "event_date_time" => "2026-02-20T20:00:00Z",
          "event_location" => "Second Venue",
          "sold_tickets" => 20,
          "checked_tickets" => 0,
          "pass" => true
        },
        ticket_delay_ms: 700
      )

      {:ok, view, _html} = mount_dashboard(conn)

      view
      |> element("#full-sync-#{existing_event.id}")
      |> render_click()

      assert render(view) =~ "Starting full attendee sync (attempt 1/3)..."

      view
      |> element("#show-new-event-form-button")
      |> render_click()

      view
      |> form("#create-event-form", %{
        "event" => %{
          "tickera_api_key_encrypted" => "new-live-api-key",
          "mobile_access_code" => "second-door-secret",
          "tickera_site_url" => "https://voelgoed.co.za",
          "location" => "",
          "entrance_name" => ""
        }
      })
      |> render_submit()

      created = Repo.get_by!(Event, name: "Second Event")
      assert render(view) =~ "CREATED_PENDING_SERVER_GRANT"
      refute render(view) =~ "Auto full sync not started"
      refute has_element?(view, "#full-sync-#{created.id}")

      assert_sync_finishes(view)
    end

    test "a pre-granted future Event ID still does not trigger creation side effects", %{
      conn: conn
    } do
      configure_dashboard_creation(true)
      future_event_id = next_event_id!()
      test_pid = self()

      mock_tickera_requests(
        %{
          "event_name" => "Prelisted Future Event",
          "event_date_time" => "2026-02-20T20:00:00Z",
          "event_location" => "Future Venue",
          "sold_tickets" => 20,
          "checked_tickets" => 0,
          "pass" => true
        },
        on_request: fn path ->
          if String.contains?(path, "tickets_info"),
            do: send(test_pid, :future_create_started_sync)
        end
      )

      {:ok, view, _html} = mount_dashboard(conn, [future_event_id])
      view |> element("#show-new-event-form-button") |> render_click()

      view
      |> form("#create-event-form", %{
        "event" => %{
          "tickera_api_key_encrypted" => "prelisted-api-key",
          "mobile_access_code" => "future-door-secret",
          "tickera_site_url" => "https://voelgoed.co.za",
          "location" => "",
          "entrance_name" => ""
        }
      })
      |> render_submit()

      created = Repo.get!(Event, future_event_id)
      assert created.name == "Prelisted Future Event"
      assert has_element?(view, "#full-sync-#{future_event_id}")
      refute created.whatsapp_sales_enabled
      assert render(view) =~ "CREATED_PENDING_SERVER_GRANT"
      refute render(view) =~ "Starting full attendee sync"
      refute_receive :future_create_started_sync, 100
    end
  end

  describe "reveal scanner password" do
    @dashboard_pw "dashboard-reveal-test-pw"

    setup do
      previous_auth = Application.get_env(:fastcheck, :dashboard_auth)
      previous_window = Application.get_env(:fastcheck, :dashboard_reveal_rate_limit_window_ms)
      previous_lock = Application.get_env(:fastcheck, :dashboard_reveal_lock_duration_ms)
      previous_max = Application.get_env(:fastcheck, :dashboard_reveal_max_failures)

      Application.put_env(:fastcheck, :dashboard_auth, %{
        username: "admin",
        password: @dashboard_pw
      })

      Application.put_env(:fastcheck, :dashboard_reveal_rate_limit_window_ms, 5_000)
      Application.put_env(:fastcheck, :dashboard_reveal_lock_duration_ms, 10_000)
      Application.put_env(:fastcheck, :dashboard_reveal_max_failures, 3)

      on_exit(fn ->
        restore_env(:dashboard_auth, previous_auth)
        restore_env(:dashboard_reveal_rate_limit_window_ms, previous_window)
        restore_env(:dashboard_reveal_lock_duration_ms, previous_lock)
        restore_env(:dashboard_reveal_max_failures, previous_max)
      end)

      :ok
    end

    test "View password is disabled when event has no mobile secret", %{conn: conn} do
      event =
        insert_event!(%{
          name: "No Secret Event",
          mobile_secret: "temp"
        })

      {1, _} =
        Repo.update_all(from(e in Event, where: e.id == ^event.id),
          set: [mobile_access_secret_encrypted: nil]
        )

      {:ok, view, _html} = mount_dashboard(conn)

      disabled_btn = view |> element("#view-scanner-password-#{event.id}") |> render()
      assert disabled_btn =~ "disabled"
    end

    test "card flow: wrong password then correct reveals secret with clipboard payload", %{
      conn: conn
    } do
      secret = "scanner-secret-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Reveal Card", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#view-scanner-password-#{event.id}") |> render_click()
      assert has_element?(view, "#reveal-secret-form")

      view
      |> form("#reveal-secret-form", %{
        "source" => "card",
        "event_id" => to_string(event.id),
        "admin_password" => "wrong-password"
      })
      |> render_submit()

      refute render(view) =~ ~s(data-clipboard-text="#{secret}")

      html =
        view
        |> form("#reveal-secret-form", %{
          "source" => "card",
          "event_id" => to_string(event.id),
          "admin_password" => @dashboard_pw
        })
        |> render_submit()

      assert html =~ ~s(data-clipboard-text="#{secret}")
    end

    test "card flow: hide clears secret from markup", %{conn: conn} do
      secret = "hide-me-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Hide Card", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#view-scanner-password-#{event.id}") |> render_click()

      view
      |> form("#reveal-secret-form", %{
        "source" => "card",
        "event_id" => to_string(event.id),
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      assert render(view) =~ secret

      view |> element("#reveal-secret-hide-value") |> render_click()
      refute render(view) =~ secret
    end

    test "card flow: closing modal clears secret", %{conn: conn} do
      secret = "close-me-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Close Card", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#view-scanner-password-#{event.id}") |> render_click()

      view
      |> form("#reveal-secret-form", %{
        "source" => "card",
        "event_id" => to_string(event.id),
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      assert render(view) =~ secret

      view |> element("#reveal-secret-close-modal") |> render_click()
      refute render(view) =~ secret
    end

    test "lockout blocks attempts until lock expires", %{conn: conn} do
      event = insert_event!(%{name: "Lockout", mobile_secret: "s"})

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#view-scanner-password-#{event.id}") |> render_click()

      for _ <- 1..3 do
        view
        |> form("#reveal-secret-form", %{
          "source" => "card",
          "event_id" => to_string(event.id),
          "admin_password" => "bad-attempt-#{System.unique_integer([:positive])}"
        })
        |> render_submit()
      end

      html =
        view
        |> form("#reveal-secret-form", %{
          "source" => "card",
          "event_id" => to_string(event.id),
          "admin_password" => @dashboard_pw
        })
        |> render_submit()

      assert html =~ "Too many incorrect attempts"

      view
      |> element("#reveal-secret-modal button[phx-click='hide_reveal_secret']")
      |> render_click()

      view |> element("#view-scanner-password-#{event.id}") |> render_click()

      html =
        view
        |> form("#reveal-secret-form", %{
          "source" => "card",
          "event_id" => to_string(event.id),
          "admin_password" => @dashboard_pw
        })
        |> render_submit()

      assert html =~ "Too many incorrect attempts"

      Process.sleep(10_100)

      html =
        view
        |> form("#reveal-secret-form", %{
          "source" => "card",
          "event_id" => to_string(event.id),
          "admin_password" => @dashboard_pw
        })
        |> render_submit()

      assert html =~ ~s(data-clipboard-text="s")
    end

    test "edit modal flow: reveal current password with re-auth", %{conn: conn} do
      secret = "edit-flow-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Edit Reveal", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn)

      view |> element("#show-edit-event-#{event.id}") |> render_click()
      view |> element("#edit-reveal-show-challenge") |> render_click()

      view
      |> form("#edit-reveal-secret-form", %{
        "source" => "edit_modal",
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      assert render(view) =~ secret
      assert render(view) =~ ~s(data-clipboard-text="#{secret}")

      view |> element("#edit-reveal-hide-value") |> render_click()
      refute render(view) =~ secret
    end

    test "card reveal confirmation is denied after the Event grant is revoked", %{conn: conn} do
      secret = "revoked-card-secret-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Revoked Card Reveal", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      view |> element("#view-scanner-password-#{event.id}") |> render_click()
      SalesWebFixtures.configure_dashboard_grants([])

      view
      |> form("#reveal-secret-form", %{
        "source" => "card",
        "event_id" => to_string(event.id),
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      refute render(view) =~ secret
      refute has_element?(view, "#reveal-secret-form")
    end

    test "edit-modal reveal confirmation is denied after the Event grant is revoked", %{
      conn: conn
    } do
      secret = "revoked-edit-secret-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Revoked Edit Reveal", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      view |> element("#show-edit-event-#{event.id}") |> render_click()
      view |> element("#edit-reveal-show-challenge") |> render_click()
      SalesWebFixtures.configure_dashboard_grants([])

      view
      |> form("#edit-reveal-secret-form", %{
        "source" => "edit_modal",
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      refute render(view) =~ secret
      refute has_element?(view, "#edit-event-form")
    end

    test "a stale revealed secret is cleared when a forged action tries to show it", %{
      conn: conn
    } do
      secret = "revoked-toggle-secret-#{System.unique_integer([:positive])}"
      event = insert_event!(%{name: "Revoked Toggle Reveal", mobile_secret: secret})

      {:ok, view, _html} = mount_dashboard(conn, [event.id])
      view |> element("#view-scanner-password-#{event.id}") |> render_click()

      view
      |> form("#reveal-secret-form", %{
        "source" => "card",
        "event_id" => to_string(event.id),
        "admin_password" => @dashboard_pw
      })
      |> render_submit()

      assert render(view) =~ secret
      SalesWebFixtures.configure_dashboard_grants([])
      render_click(view, "toggle_reveal_secret_plain", %{})
      refute render(view) =~ secret
    end
  end

  defp restore_env(key, previous) do
    if is_nil(previous) do
      Application.delete_env(:fastcheck, key)
    else
      Application.put_env(:fastcheck, key, previous)
    end
  end

  defp mount_dashboard(conn, event_ids \\ nil) do
    event_ids = event_ids || Repo.all(from(event in Event, select: event.id))
    SalesWebFixtures.configure_dashboard_grants(event_ids)

    conn
    |> init_test_session(%{dashboard_authenticated: true, dashboard_username: "admin"})
    |> live(~p"/dashboard")
  end

  defp insert_event!(attrs) do
    api_key = Map.get(attrs, :tickera_api_key, "tickera-api-key")
    mobile_secret = Map.get(attrs, :mobile_secret, "old-scanner-secret")
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    defaults = %{
      name: "Event #{System.unique_integer([:positive])}",
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      status: "active",
      entrance_name: "Main Gate",
      location: "Main Venue"
    }

    params =
      defaults
      |> Map.merge(attrs)
      |> Map.delete(:tickera_api_key)
      |> Map.delete(:mobile_secret)

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end

  defp mock_tickera_requests(event_essentials, opts) do
    ticket_delay_ms = Keyword.get(opts, :ticket_delay_ms, 0)
    ticket_request_fun = Keyword.get(opts, :ticket_request_fun)
    on_request = Keyword.get(opts, :on_request)

    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""
      if is_function(on_request, 1), do: on_request.(path)

      cond do
        String.ends_with?(path, "/check_credentials") ->
          {:ok, %Response{status: 200, body: %{"pass" => true}}}

        String.ends_with?(path, "/event_essentials") ->
          {:ok, %Response{status: 200, body: Map.put_new(event_essentials, "pass", true)}}

        String.contains?(path, "/tickets_info/") ->
          ticket_info_response(ticket_request_fun, path, ticket_delay_ms)

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end

  defp ticket_info_response(ticket_request_fun, path, ticket_delay_ms) do
    case ticket_request_fun do
      fun when is_function(fun, 1) ->
        fun.(path)

      _ ->
        if ticket_delay_ms > 0, do: Process.sleep(ticket_delay_ms)

        {:ok,
         %Response{status: 200, body: %{"data" => [], "additional" => %{"results_count" => 0}}}}
    end
  end

  defp configure_dashboard_creation(enabled) when is_boolean(enabled) do
    auth = Application.get_env(:fastcheck, :dashboard_auth, %{})

    Application.put_env(
      :fastcheck,
      :dashboard_auth,
      Map.put(auth, :event_creation_enabled, enabled)
    )
  end

  defp next_event_id! do
    %{rows: [[event_id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('events', 'id'))")

    Repo.query!(
      "SELECT setval(pg_get_serial_sequence('events', 'id')::regclass, $1, false)",
      [event_id]
    )

    event_id
  end

  defp assert_sync_finishes(view, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_sync_finishes(view, deadline)
  end

  defp do_assert_sync_finishes(view, deadline) do
    html = render(view)

    cond do
      html =~ "Sync complete!" or html =~ "Synced " ->
        :ok

      html =~ "Sync failed:" ->
        flunk("expected sync to complete cleanly, got: #{html}")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for dashboard sync to finish")

      true ->
        Process.sleep(50)
        do_assert_sync_finishes(view, deadline)
    end
  end
end
