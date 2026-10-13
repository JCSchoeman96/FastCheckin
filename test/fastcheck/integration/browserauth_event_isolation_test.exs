defmodule FastCheck.Integration.BrowserAuthEventIsolationTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Attendees.{Attendee, CheckIn, CheckInSession}
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures

  @missing_event_id 2_147_483_647

  setup do
    previous_dashboard_auth = Application.get_env(:fastcheck, :dashboard_auth)

    on_exit(fn ->
      if is_nil(previous_dashboard_auth) do
        Application.delete_env(:fastcheck, :dashboard_auth)
      else
        Application.put_env(:fastcheck, :dashboard_auth, previous_dashboard_auth)
      end
    end)

    :ok
  end

  test "the current server grant scopes dashboard, exports, scanner, and occupancy", %{
    conn: _conn
  } do
    event_a =
      insert_event(
        "B5_GRANTED_EVENT_A",
        "B5_GRANTED_EVENT_A attendee sentinel",
        "A-TICKET-SENTINEL"
      )

    event_b =
      insert_event(
        "B5_UNGRANTED_EVENT_B",
        "B5_UNGRANTED_EVENT_B attendee sentinel",
        "B-TICKET-SENTINEL"
      )

    set_grants([event_a.id])
    assert_event_surfaces_grant(event_a, event_b)

    set_grants([event_b.id])
    assert_event_surfaces_grant(event_b, event_a)
  end

  test "an empty grant set denies all existing Event data across the four surfaces", %{
    conn: _conn
  } do
    event =
      insert_event(
        "B5_EMPTY_GRANT_EVENT",
        "B5_EMPTY_GRANT_EVENT attendee sentinel",
        "EMPTY-TICKET"
      )

    set_grants([])

    {:ok, dashboard, _html} = live(authenticated_conn(), "/dashboard")
    refute has_element?(dashboard, ".fc-card-container")
    refute render(dashboard) =~ event.name
    refute render(dashboard) =~ "B5_EMPTY_GRANT_EVENT attendee sentinel"

    assert_export_denied(:attendees, event)
    assert_export_denied(:check_ins, event)
    assert_scanner_denied(event)
    assert_occupancy_denied(event)
  end

  defp assert_event_surfaces_grant(granted_event, denied_event) do
    {:ok, dashboard, _html} = live(authenticated_conn(), "/dashboard")
    assert has_element?(dashboard, ".fc-card-container", granted_event.name)
    refute has_element?(dashboard, ".fc-card-container", denied_event.name)
    refute render(dashboard) =~ "#{denied_event.name} attendee sentinel"

    assert_export_granted(:attendees, granted_event)
    assert_export_granted(:check_ins, granted_event)
    assert_export_denied(:attendees, denied_event)
    assert_export_denied(:check_ins, denied_event)

    {:ok, scanner, _html} = live(authenticated_conn(), "/scan/#{granted_event.id}")
    assert has_element?(scanner, "#admin-scanner-root")
    assert render(scanner) =~ granted_event.name
    assert_scanner_denied(denied_event)

    {:ok, occupancy, _html} =
      live(authenticated_conn(), "/dashboard/occupancy/#{granted_event.id}")

    assert render(occupancy) =~ granted_event.name
    assert_occupancy_denied(denied_event)
  end

  defp assert_export_granted(:attendees, event) do
    conn = get(authenticated_conn(), "/export/attendees/#{event.id}")

    assert conn.status == 200
    assert FastCheckWeb.ConnCase.response_content_type(conn, :csv)
    assert hd(get_resp_header(conn, "content-disposition")) =~ "#{event.name}_attendees_"
    assert conn.resp_body =~ event.ticket_code
  end

  defp assert_export_granted(:check_ins, event) do
    conn = get(authenticated_conn(), "/export/check-ins/#{event.id}")

    assert conn.status == 200
    assert FastCheckWeb.ConnCase.response_content_type(conn, :csv)
    assert hd(get_resp_header(conn, "content-disposition")) =~ "#{event.name}_check_ins_"
    assert conn.resp_body =~ event.ticket_code
    assert conn.resp_body =~ "#{event.name} operator sentinel"
  end

  defp assert_export_denied(kind, event) do
    denied = get(authenticated_conn(), export_path(kind, event.id))
    missing = get(authenticated_conn(), export_path(kind, @missing_event_id))

    assert_safe_export_denial(denied)
    assert_safe_export_denial(missing)
    assert denied.resp_body == missing.resp_body
    refute denied.resp_body =~ event.name
    refute denied.resp_body =~ event.ticket_code
  end

  defp assert_safe_export_denial(conn) do
    assert conn.status == 404
    refute FastCheckWeb.ConnCase.response_content_type(conn, :csv)
    assert get_resp_header(conn, "content-disposition") == []
    assert json_response(conn, 404) == %{"error" => "Event not found"}
  end

  defp assert_scanner_denied(event) do
    assert_live_denial(
      "/scan/#{event.id}",
      "/scan/#{@missing_event_id}",
      "/dashboard",
      event.name
    )

    assert is_nil(Repo.get!(Attendee, event.attendee_id).checked_in_at)
    refute Repo.get_by(CheckInSession, event_id: event.id)
  end

  defp assert_occupancy_denied(event) do
    assert_live_denial(
      "/dashboard/occupancy/#{event.id}",
      "/dashboard/occupancy/#{@missing_event_id}",
      "/",
      event.name
    )
  end

  defp assert_live_denial(path, missing_path, redirect_to, event_name) do
    assert {:error, {:live_redirect, denied}} = live(authenticated_conn(), path)
    assert {:error, {:live_redirect, missing}} = live(authenticated_conn(), missing_path)

    assert denied.to == redirect_to
    assert denied.to == missing.to
    assert denied.flash == missing.flash
    assert denied.flash["error"] == "Event not found"
    refute inspect(denied) =~ event_name
  end

  defp insert_event(name, attendee_name, ticket_code) do
    event = SalesWebFixtures.insert_event!(%{name: name, total_tickets: 733})

    attendee =
      Fixtures.create_attendee(event, %{
        first_name: attendee_name,
        last_name: "B5",
        ticket_code: ticket_code,
        email: "#{String.downcase(ticket_code)}@example.test"
      })

    %CheckIn{}
    |> CheckIn.changeset(%{
      attendee_id: attendee.id,
      event_id: event.id,
      ticket_code: attendee.ticket_code,
      checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second),
      entrance_name: "B5 entrance sentinel",
      operator_name: "#{name} operator sentinel",
      status: "success",
      notes: "B5 Event export sentinel"
    })
    |> Repo.insert!()

    event
    |> Map.put(:ticket_code, ticket_code)
    |> Map.put(:attendee_id, attendee.id)
  end

  defp set_grants(event_ids) do
    auth = Application.get_env(:fastcheck, :dashboard_auth, %{})

    Application.put_env(
      :fastcheck,
      :dashboard_auth,
      auth
      |> Map.put(:username, SalesWebFixtures.dashboard_username())
      |> Map.put(:allowed_event_ids, event_ids)
    )
  end

  defp authenticated_conn do
    conn = SalesWebFixtures.authenticated_conn(build_conn())
    refute get_session(conn, :allowed_event_ids)
    conn
  end

  defp export_path(:attendees, event_id), do: "/export/attendees/#{event_id}"
  defp export_path(:check_ins, event_id), do: "/export/check-ins/#{event_id}"
end
