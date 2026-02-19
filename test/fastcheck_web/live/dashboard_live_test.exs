defmodule FastCheckWeb.DashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias Req.Response

  setup do
    _ = Cache.invalidate_events_list_cache()

    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)
    previous_default_site_url = Application.get_env(:fastcheck, :default_tickera_site_url)

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
    end)

    :ok
  end

  describe "edit event modal" do
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
      name_input_html = view |> element("#edit-event-form input[name='event[name]']") |> render()

      site_url_input_html =
        view
        |> element("#edit-event-form input[name='event[tickera_site_url]']")
        |> render()

      location_input_html =
        view
        |> element("#edit-event-form input[name='event[location]']")
        |> render()

      entrance_input_html =
        view
        |> element("#edit-event-form input[name='event[entrance_name]']")
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

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#open-scanner-#{event.id}", "Open scanner")
      assert has_element?(view, "#show-sync-history-#{event.id}", "Sync history")
      assert has_element?(view, "#show-edit-event-#{event.id}", "Edit event")
      assert has_element?(view, "#export-attendees-#{event.id}", "Export attendees")
      assert has_element?(view, "#export-checkins-#{event.id}", "Export check-ins")
      refute has_element?(view, "#open-scanner-#{event.id}", "Opening...")
      refute has_element?(view, "#show-sync-history-#{event.id}", "Opening...")
      refute has_element?(view, "#show-edit-event-#{event.id}", "Opening...")
      refute has_element?(view, "#export-attendees-#{event.id}", "Preparing...")
      refute has_element?(view, "#export-checkins-#{event.id}", "Preparing...")
    end
  end

  describe "create event flow" do
    test "create form is minimal by default and pre-fills Tickera site URL", %{conn: conn} do
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

      site_url_input_html =
        view
        |> element("#create-event-form input[name='event[tickera_site_url]']")
        |> render()

      assert site_url_input_html =~ ~s(value="https://voelgoed.co.za")
    end

    test "submitting minimal create form auto-starts full sync in background", %{conn: conn} do
      mock_tickera_requests(
        %{
          "event_name" => "Auto Sync Event",
          "event_date_time" => "2026-02-19T19:00:00Z",
          "event_location" => "Auto Venue",
          "sold_tickets" => 75,
          "checked_tickets" => 3,
          "pass" => true
        },
        ticket_delay_ms: 250
      )

      {:ok, view, _html} = mount_dashboard(conn)

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

      created =
        Events.list_events()
        |> Enum.find(&(&1.name == "Auto Sync Event"))

      assert %Event{} = created
      assert created.entrance_name == "Main Gate"

      html = render(view)

      assert html =~
               "Event created: ID #{created.id}, scanner code #{created.scanner_login_code}."

      assert html =~ "Starting full attendee sync"
      refute has_element?(view, "#create-event-form")
    end

    test "create flow warns when another sync is already running", %{conn: conn} do
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

      assert render(view) =~ "Auto full sync not started because another sync is already running."
    end
  end

  defp mount_dashboard(conn) do
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

    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""

      cond do
        String.ends_with?(path, "/check_credentials") ->
          {:ok, %Response{status: 200, body: %{"pass" => true}}}

        String.ends_with?(path, "/event_essentials") ->
          {:ok, %Response{status: 200, body: Map.put_new(event_essentials, "pass", true)}}

        String.contains?(path, "/tickets_info/") ->
          if ticket_delay_ms > 0, do: Process.sleep(ticket_delay_ms)

          {:ok,
           %Response{status: 200, body: %{"data" => [], "additional" => %{"results_count" => 0}}}}

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end
end
