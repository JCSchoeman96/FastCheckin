defmodule FastCheckWeb.CheckInControllerTest do
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

  describe "create" do
    test "processes check-in using authenticated event context", %{conn: conn, attendee: attendee} do
      conn =
        post(conn, ~p"/api/v1/check-in", %{
          "ticket_code" => attendee.ticket_code,
          "entrance_name" => "Gate A"
        })

      assert %{"data" => data, "error" => nil} = json_response(conn, 200)
      assert data["status"] == "SUCCESS"
      assert data["ticket_code"] == attendee.ticket_code
      assert data["attendee_id"] == attendee.id
    end

    test "rejects unauthenticated requests", %{conn: conn} do
      conn = delete_req_header(conn, "authorization")

      conn = post(conn, ~p"/api/v1/check-in", %{"ticket_code" => "CODE"})

      assert json_response(conn, 401)["error"] == "missing_authorization_header"
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
