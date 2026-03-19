defmodule FastCheckWeb.Api.V1.DeviceSessionControllerTest do
  use FastCheckWeb.ConnCase, async: true

  import FastCheck.Fixtures

  @moduletag skip: "Future native-scanner scaffold routes are not mounted in FastCheckWeb.Router"

  test "creates a revocable device session from scanner code and credential", %{conn: conn} do
    event = create_event(%{mobile_access_code: "door-secret"})

    conn =
      post(conn, "/api/v1/device_sessions", %{
        "scanner_code" => event.scanner_login_code,
        "credential" => "door-secret",
        "device_installation_id" => "device-installation-1",
        "operator_name" => "Gate Operator",
        "app_version" => "0.1.0"
      })

    assert %{
             "data" => %{
               "token" => token,
               "device_id" => device_id,
               "session_id" => session_id,
               "event_id" => event_id
             },
             "error" => nil
           } = json_response(conn, 200)

    assert is_binary(token)
    assert is_integer(device_id)
    assert is_integer(session_id)
    assert event_id == event.id
  end
end
