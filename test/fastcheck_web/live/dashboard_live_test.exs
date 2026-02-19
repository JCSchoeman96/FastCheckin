defmodule FastCheckWeb.DashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  setup do
    _ = Cache.invalidate_events_list_cache()
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
end
