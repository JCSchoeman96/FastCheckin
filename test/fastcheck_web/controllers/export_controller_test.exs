defmodule FastCheckWeb.ExportControllerTest do
  use FastCheckWeb.ConnCase, async: false

  alias FastCheck.Attendees.CheckIn
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Fixtures
  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  @nonexistent_event_id 2_147_483_647

  describe "GET /export/attendees/:event_id" do
    test "exports granted Event attendees and excludes another Event's attendees" do
      event_a = insert_event!("Event A Granted")
      event_b = insert_event!("Event B Private")
      attendee_a = insert_attendee!(event_a, "ATTENDEE-A-SENTINEL")
      attendee_b = insert_attendee!(event_b, "ATTENDEE-B-PRIVATE-SENTINEL")

      conn = export(:attendees, event_a.id, [event_a.id])

      assert conn.status == 200
      assert FastCheckWeb.ConnCase.response_content_type(conn, :csv)

      assert hd(get_resp_header(conn, "content-disposition")) =~
               "Event_A_Granted_attendees_"

      assert conn.resp_body =~ attendee_a.ticket_code
      refute conn.resp_body =~ attendee_b.ticket_code
      refute conn.resp_body =~ event_b.name
    end

    test "denies a forged URL for an existing ungranted Event like a missing Event" do
      granted_event = insert_event!("Event A Granted")
      ungranted_event = insert_event!("Event B Private")
      private_attendee = insert_attendee!(ungranted_event, "ATTENDEE-B-PRIVATE-SENTINEL")

      denied = export(:attendees, ungranted_event.id, [granted_event.id])
      missing = export(:attendees, @nonexistent_event_id, [granted_event.id])

      assert assert_safe_not_found(denied) == assert_safe_not_found(missing)
      refute denied.resp_body =~ ungranted_event.name
      refute denied.resp_body =~ private_attendee.ticket_code
    end
  end

  describe "GET /export/check-ins/:event_id" do
    test "exports granted Event check-ins and excludes another Event's check-ins" do
      event_a = insert_event!("Event A Granted")
      event_b = insert_event!("Event B Private")
      attendee_a = insert_attendee!(event_a, "CHECKIN-A-TICKET-SENTINEL")
      attendee_b = insert_attendee!(event_b, "CHECKIN-B-TICKET-PRIVATE-SENTINEL")
      check_in_a = insert_check_in!(event_a, attendee_a, "Operator A Sentinel")
      check_in_b = insert_check_in!(event_b, attendee_b, "Operator B Private Sentinel")

      conn = export(:check_ins, event_a.id, [event_a.id])

      assert conn.status == 200
      assert FastCheckWeb.ConnCase.response_content_type(conn, :csv)

      assert hd(get_resp_header(conn, "content-disposition")) =~
               "Event_A_Granted_check_ins_"

      assert conn.resp_body =~ attendee_a.ticket_code
      assert conn.resp_body =~ check_in_a.operator_name
      refute conn.resp_body =~ attendee_b.ticket_code
      refute conn.resp_body =~ check_in_b.operator_name
      refute conn.resp_body =~ event_b.name
    end

    test "denies a forged URL for an existing ungranted Event like a missing Event" do
      granted_event = insert_event!("Event A Granted")
      ungranted_event = insert_event!("Event B Private")
      private_attendee = insert_attendee!(ungranted_event, "CHECKIN-B-TICKET-PRIVATE-SENTINEL")
      private_check_in = insert_check_in!(ungranted_event, private_attendee, "Private Operator")

      denied = export(:check_ins, ungranted_event.id, [granted_event.id])
      missing = export(:check_ins, @nonexistent_event_id, [granted_event.id])

      assert assert_safe_not_found(denied) == assert_safe_not_found(missing)
      refute denied.resp_body =~ ungranted_event.name
      refute denied.resp_body =~ private_attendee.ticket_code
      refute denied.resp_body =~ private_check_in.operator_name
    end
  end

  test "an empty grant set denies both export endpoints" do
    event = insert_event!("Event With No Grants")

    for kind <- [:attendees, :check_ins] do
      event_id = Integer.to_string(event.id)
      conn = export(kind, event_id, [])

      assert_safe_not_found(conn)
    end
  end

  test "malformed Event IDs retain the existing invalid-input response" do
    for kind <- [:attendees, :check_ins] do
      conn = export(kind, "not-an-event-id", [])

      assert conn.status == 400
      assert json_response(conn, 400) == %{"error" => "Invalid event ID"}
      refute FastCheckWeb.ConnCase.response_content_type(conn, :csv)
      assert get_resp_header(conn, "content-disposition") == []
    end
  end

  defp export(kind, event_id, granted_event_ids) do
    conn = WebFixtures.authenticated_conn(build_conn(), granted_event_ids)
    get(conn, route_for(kind, event_id))
  end

  defp route_for(:attendees, event_id), do: "/export/attendees/#{event_id}"
  defp route_for(:check_ins, event_id), do: "/export/check-ins/#{event_id}"

  defp assert_safe_not_found(conn) do
    assert conn.status == 404
    refute FastCheckWeb.ConnCase.response_content_type(conn, :csv)
    assert get_resp_header(conn, "content-disposition") == []
    assert json_response(conn, 404) == %{"error" => "Event not found"}

    %{
      status: conn.status,
      body: conn.resp_body,
      content_type: get_resp_header(conn, "content-type"),
      disposition: get_resp_header(conn, "content-disposition")
    }
  end

  defp insert_event!(name) do
    api_key = "tickera-api-key"
    mobile_secret = "scanner-secret"
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = Crypto.encrypt(mobile_secret)

    %Event{}
    |> Event.changeset(%{
      name: name,
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_mobile_secret,
      scanner_login_code: Fixtures.unique_scanner_login_code(),
      status: "active",
      entrance_name: "Main Gate",
      location: "Main Venue"
    })
    |> Repo.insert!()
  end

  defp insert_attendee!(event, ticket_code) do
    Fixtures.create_attendee(event, %{
      ticket_code: ticket_code,
      first_name: "Sentinel",
      last_name: ticket_code,
      email: "#{String.downcase(ticket_code)}@example.test"
    })
  end

  defp insert_check_in!(event, attendee, operator_name) do
    %CheckIn{}
    |> CheckIn.changeset(%{
      attendee_id: attendee.id,
      event_id: event.id,
      ticket_code: attendee.ticket_code,
      checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second),
      entrance_name: "Sentinel Entrance",
      operator_name: operator_name,
      status: "success",
      notes: "Event-specific export sentinel"
    })
    |> Repo.insert!()
  end
end
