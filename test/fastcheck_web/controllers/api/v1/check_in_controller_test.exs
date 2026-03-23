defmodule FastCheckWeb.Api.V1.CheckInControllerTest do
  use FastCheckWeb.ConnCase, async: true

  import Ecto.Query

  import FastCheck.Fixtures

  alias FastCheck.CheckIns.CheckInAttempt
  alias FastCheck.Repo

  @moduletag skip: "Future native-scanner scaffold routes are not mounted in FastCheckWeb.Router"

  test "writes audit rows and rejects duplicate confirmed scans", %{conn: conn} do
    event = create_event(%{mobile_access_code: "scan-secret"})
    gate = create_gate(event, %{name: "Main", slug: "main"})
    attendee = create_attendee(event, %{ticket_code: "VIP-001"})

    token =
      create_session_token(conn, event, gate, "scan-secret", "scanner-1")

    first_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/check_ins", %{
        "ticket_code" => attendee.ticket_code,
        "event_id" => event.id,
        "gate_id" => gate.id,
        "request_id" => "req-1",
        "scanned_at_device" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "app_version" => "0.1.0",
        "connectivity_mode" => "online"
      })

    assert %{"data" => %{"decision" => "accepted_confirmed", "status" => "accepted"}} =
             json_response(first_conn, 200)

    second_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/check_ins", %{
        "ticket_code" => attendee.ticket_code,
        "event_id" => event.id,
        "gate_id" => gate.id,
        "request_id" => "req-2",
        "scanned_at_device" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "app_version" => "0.1.0",
        "connectivity_mode" => "online"
      })

    assert %{"data" => %{"decision" => "rejected_duplicate", "status" => "rejected"}} =
             json_response(second_conn, 200)

    audit_count =
      CheckInAttempt
      |> where([attempt], attempt.event_id == ^event.id)
      |> Repo.aggregate(:count)

    assert audit_count == 2
  end

  test "distinguishes offline-approved scans from confirmed scans", %{conn: conn} do
    event =
      create_event(%{
        mobile_access_code: "offline-secret",
        scanner_policy_mode: "offline_capable"
      })

    gate = create_gate(event, %{name: "North Gate", slug: "north-gate"})
    attendee = create_attendee(event, %{ticket_code: "OFF-100"})

    token =
      create_session_token(conn, event, gate, "offline-secret", "scanner-2")

    offline_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/check_ins", %{
        "ticket_code" => attendee.ticket_code,
        "event_id" => event.id,
        "gate_id" => gate.id,
        "request_id" => "offline-1",
        "scanned_at_device" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "app_version" => "0.1.0",
        "connectivity_mode" => "offline"
      })

    assert %{
             "data" => %{
               "decision" => "accepted_offline_pending",
               "reconciliation_state" => "pending",
               "status" => "accepted"
             }
           } = json_response(offline_conn, 200)
  end

  defp create_session_token(conn, event, gate, credential, installation_id) do
    session_conn =
      post(conn, "/api/v1/device_sessions", %{
        "scanner_code" => event.scanner_login_code,
        "credential" => credential,
        "device_installation_id" => installation_id,
        "gate_id" => gate.id
      })

    json_response(session_conn, 200)["data"]["token"]
  end
end
