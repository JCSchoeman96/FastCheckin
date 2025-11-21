defmodule FastCheckWeb.BulkCheckInControllerTest do
  use FastCheckWeb.ConnCase

  import FastCheck.EventsFixtures
  import FastCheck.AttendeesFixtures

  setup %{conn: conn} do
    event = event_fixture()
    attendee = attendee_fixture(event_id: event.id)

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"), event: event, attendee: attendee}
  end

  describe "create batch check-in" do
    test "processes valid scans", %{conn: conn, event: event, attendee: attendee} do
      conn =
        post(conn, ~p"/api/v1/check-in/batch", %{
          "event_id" => event.id,
          "scans" => [
            %{"ticket_code" => attendee.ticket_code, "entrance_name" => "Main"}
          ]
        })

      assert %{"results" => results} = json_response(conn, 200)
      assert length(results) == 1
      result = List.first(results)
      assert result["status"] == "SUCCESS"
      assert result["ticket_code"] == attendee.ticket_code
    end

    test "handles invalid event_id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/check-in/batch", %{
          "event_id" => "invalid",
          "scans" => []
        })

      assert json_response(conn, 400)["error"] == "INVALID_EVENT"
    end

    test "handles missing scans", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/check-in/batch", %{})
      assert json_response(conn, 400)["error"] == "INVALID_PAYLOAD"
    end
  end
end
