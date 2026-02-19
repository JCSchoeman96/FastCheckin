defmodule FastCheckWeb.Plugs.RateLimiterTest do
  use FastCheckWeb.ConnCase

  setup do
    # Clear rate limiter storage before tests
    PlugAttack.Storage.Ets.clean(FastCheck.RateLimiter)
    :ok
  end

  test "login endpoint is strictly rate limited to 5 attempts", %{conn: conn} do
    conn = put_req_header(conn, "x-forwarded-for", "203.0.113.9")

    # Make 5 allowed requests
    for _i <- 1..5 do
      conn = post(conn, "/api/v1/mobile/login", %{"event_id" => 1, "credential" => "wrong"})
      # Any error status is fine, just not 429
      assert conn.status in [401, 403, 404, 400]
      refute conn.status == 429
    end

    # Make 6th request - should be blocked
    conn = post(conn, "/api/v1/mobile/login", %{"event_id" => 1, "credential" => "wrong"})
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
  end

  test "dashboard login is also rate limited", %{conn: conn} do
    conn = put_req_header(conn, "x-forwarded-for", "203.0.113.10")

    # Make 5 allowed requests
    for _i <- 1..5 do
      conn = post(conn, "/login", %{"session" => %{"username" => "admin", "password" => "wrong"}})
      # 200 if renders form, 302 if redirect
      assert conn.status in [200, 302, 401]
      refute conn.status == 429
    end

    # Make 6th request - should be blocked
    conn = post(conn, "/login", %{"session" => %{"username" => "admin", "password" => "wrong"}})
    assert conn.status == 429
  end
end
