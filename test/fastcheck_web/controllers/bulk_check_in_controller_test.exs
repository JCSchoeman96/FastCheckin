defmodule FastCheckWeb.BulkCheckInControllerTest do
  use FastCheckWeb.ConnCase

  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token

  setup %{conn: conn} do
    event = create_event()
    attendee = create_attendee(event)
    {:ok, token} = Token.issue_scanner_token(event.id)

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    {:ok, conn: authed_conn, event: event, attendee: attendee}
  end

  describe "create batch check-in" do
    test "processes valid scans", %{conn: conn, attendee: attendee} do
      conn =
        post(conn, ~p"/api/v1/check-in/batch", %{
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

    test "rejects unauthenticated requests", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")

      conn = post(conn, ~p"/api/v1/check-in/batch", %{"scans" => []})

      assert json_response(conn, 401)["error"] == "missing_authorization_header"
    end

    test "handles missing scans", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/check-in/batch", %{})
      assert json_response(conn, 400)["error"] == "INVALID_PAYLOAD"
    end
  end

  defp create_event do
    params = %{
      name: "Test Event",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: "encrypted_key",
      status: "active"
    }

    %Event{}
    |> Event.changeset(params)
    |> Repo.insert!()
  end

  defp create_attendee(event) do
    params = %{
      event_id: event.id,
      ticket_code: "TICKET-#{System.unique_integer([:positive])}",
      allowed_checkins: 1,
      checkins_remaining: 1,
      payment_status: "completed"
    }

    %Attendee{}
    |> Attendee.changeset(params)
    |> Repo.insert!()
  end
end
