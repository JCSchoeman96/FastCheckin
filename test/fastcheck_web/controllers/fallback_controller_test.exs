defmodule FastCheckWeb.FallbackControllerTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheckWeb.FallbackController

  test "maps ticket contention error to 409 conflict", %{conn: conn} do
    conn =
      FallbackController.call(conn, {:error, "TICKET_IN_USE_ELSEWHERE", "Ticket is locked"})

    assert conn.status == 409
    assert %{"error" => %{"code" => "TICKET_IN_USE_ELSEWHERE"}} = Jason.decode!(conn.resp_body)
  end
end
