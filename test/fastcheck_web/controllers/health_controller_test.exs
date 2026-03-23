defmodule FastCheckWeb.HealthControllerTest do
  use FastCheckWeb.ConnCase, async: true

  test "GET /api/v1/live returns a process liveness payload", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/live")

    assert %{"data" => %{"status" => "alive", "timestamp" => timestamp}, "error" => nil} =
             json_response(conn, 200)

    assert is_binary(timestamp)
  end

  test "GET /api/v1/health returns a db-backed readiness payload", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/health")

    assert %{"data" => %{"status" => "healthy", "timestamp" => timestamp}, "error" => nil} =
             json_response(conn, 200)

    assert is_binary(timestamp)
  end
end
