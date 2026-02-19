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
    test "opens edit modal and renders optional API key input safely", %{conn: conn} do
      event = insert_event!(%{name: "Modal Smoke Event"})

      {:ok, view, _html} = mount_dashboard(conn)

      assert has_element?(view, "#show-edit-event-#{event.id}")

      view
      |> element("#show-edit-event-#{event.id}")
      |> render_click()

      assert has_element?(view, "#edit-event-form")
      assert has_element?(view, "#edit-event-new-api-key")
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
