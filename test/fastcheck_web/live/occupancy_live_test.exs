defmodule FastCheckWeb.OccupancyLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures

  describe "dashboard event grants" do
    test "mounts occupancy for a granted event", %{conn: conn} do
      event = SalesWebFixtures.insert_event!(%{name: "Granted Occupancy Event"})

      {:ok, view, _html} = mount_occupancy(conn, event.id, [event.id])

      assert render(view) =~ event.name
      assert render(view) =~ "Occupancy"
      assert render(view) =~ "Flow summary"
      assert render(view) =~ "Per entrance performance"
    end

    test "denies an existing ungranted event like a nonexistent event", %{conn: conn} do
      event = SalesWebFixtures.insert_event!(%{name: "Private Occupancy Sentinel"})
      granted_event = SalesWebFixtures.insert_event!()

      ungranted_result = mount_occupancy(conn, event.id, [granted_event.id])
      missing_result = mount_occupancy(conn, 999_999_999, [granted_event.id])

      assert {:error, {:live_redirect, ungranted_redirect}} = ungranted_result
      assert {:error, {:live_redirect, missing_redirect}} = missing_result
      assert ungranted_redirect.to == "/"
      assert missing_redirect.to == "/"
      assert ungranted_redirect.flash == missing_redirect.flash
      assert ungranted_redirect.flash["error"] == "Event not found"
      refute inspect(ungranted_redirect) =~ event.name
    end

    test "denies an existing event when the grant set is empty", %{conn: conn} do
      event = SalesWebFixtures.insert_event!(%{name: "Empty Grant Occupancy Sentinel"})

      assert {:error, {:live_redirect, %{to: "/", flash: flash}}} =
               mount_occupancy(conn, event.id, [])

      assert flash["error"] == "Event not found"
      refute inspect(flash) =~ event.name
    end

    test "denies revoked access before refreshing occupancy data", %{conn: conn} do
      event = SalesWebFixtures.insert_event!(%{name: "Before Refresh Sentinel"})
      {:ok, view, _html} = mount_occupancy(conn, event.id, [event.id])

      Repo.update!(Ecto.Changeset.change(event, name: "Refreshed Event Data Sentinel"))
      SalesWebFixtures.configure_dashboard_grants([])
      send(view.pid, {:occupancy_changed, 1, :check_in})

      flash = assert_redirect(view, "/")
      assert flash["error"] == "Event not found"
      refute inspect(flash) =~ "Refreshed Event Data Sentinel"
    end

    test "denies a revoked occupancy update without applying its payload", %{conn: conn} do
      event = SalesWebFixtures.insert_event!(%{name: "Revoked Occupancy Update Event"})
      {:ok, view, _html} = mount_occupancy(conn, event.id, [event.id])

      SalesWebFixtures.configure_dashboard_grants([])

      send(
        view.pid,
        {:occupancy_update,
         %{event_id: event.id, inside_count: 876_543, capacity: 999_999, percentage: 94.6}}
      )

      flash = assert_redirect(view, "/")
      assert flash["error"] == "Event not found"
      refute inspect(flash) =~ "876,543"
      refute inspect(flash) =~ "94.6"
    end
  end

  defp mount_occupancy(conn, event_id, event_ids) do
    conn
    |> SalesWebFixtures.authenticated_conn(event_ids)
    |> live(~p"/dashboard/occupancy/#{event_id}")
  end
end
