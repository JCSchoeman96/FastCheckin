defmodule FastCheckWeb.Api.V1.EventConfigControllerTest do
  use FastCheckWeb.ConnCase, async: true

  import FastCheck.Fixtures

  test "enforces event assignment on config requests", %{conn: conn} do
    event = create_event(%{mobile_access_code: "secret-a"})
    other_event = create_event(%{mobile_access_code: "secret-b"})
    _gate = create_gate(event, %{name: "VIP Gate", slug: "vip-gate"})

    session_conn =
      post(conn, ~p"/api/v1/device_sessions", %{
        "scanner_code" => event.scanner_login_code,
        "credential" => "secret-a",
        "device_installation_id" => "config-device-1"
      })

    token = json_response(session_conn, 200)["data"]["token"]

    forbidden_conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{token}")
      |> get(~p"/api/v1/events/#{other_event.id}/config")

    assert %{"error" => %{"code" => "FORBIDDEN"}} = json_response(forbidden_conn, 403)
  end
end
