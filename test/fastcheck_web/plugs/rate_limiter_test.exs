defmodule FastCheckWeb.Plugs.RateLimiterTest do
  use FastCheckWeb.ConnCase

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token
  alias FastCheck.Repo

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

  test "check-in throttle is scoped by event and authenticated identity", %{conn: conn} do
    previous = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    on_exit(fn ->
      Application.put_env(:fastcheck, FastCheck.RateLimiter, previous)
    end)

    Application.put_env(
      :fastcheck,
      FastCheck.RateLimiter,
      Keyword.merge(previous, checkin_limit: 1)
    )

    event_one = insert_event("Rate Limit Event One")
    event_two = insert_event("Rate Limit Event Two")

    {:ok, token_one} = Token.issue_scanner_token(event_one.id)
    {:ok, token_two} = Token.issue_scanner_token(event_two.id)

    payload = %{
      "ticket_code" => "UNKNOWN-TICKET",
      "entrance_name" => "Main",
      "operator_name" => "Load Test"
    }

    conn_one =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.22")
      |> put_req_header("authorization", "Bearer #{token_one}")
      |> post("/api/v1/check-in", payload)

    refute conn_one.status == 429

    conn_two =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.22")
      |> put_req_header("authorization", "Bearer #{token_one}")
      |> post("/api/v1/check-in", payload)

    assert conn_two.status == 429
    assert get_resp_header(conn_two, "retry-after") != []

    conn_three =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.22")
      |> put_req_header("authorization", "Bearer #{token_two}")
      |> post("/api/v1/check-in", payload)

    refute conn_three.status == 429
  end

  test "scan throttle returns 429 with retry headers after limit", %{conn: conn} do
    previous = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    on_exit(fn ->
      Application.put_env(:fastcheck, FastCheck.RateLimiter, previous)
    end)

    Application.put_env(
      :fastcheck,
      FastCheck.RateLimiter,
      Keyword.merge(previous, scan_limit: 1)
    )

    event = insert_event("Rate Limit Scan Event")
    {:ok, token} = Token.issue_scanner_token(event.id)

    conn_one =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.23")
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_one.status == 200

    conn_two =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.23")
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_two.status == 429
    assert get_resp_header(conn_two, "retry-after") != []
    assert Enum.join(get_resp_header(conn_two, "content-type"), ",") =~ "application/json"
  end

  defp insert_event(name) do
    api_key = "api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt("scanner-secret")

    %Event{}
    |> Event.changeset(%{
      name: name,
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_secret,
      status: "active"
    })
    |> Repo.insert!()
  end
end
