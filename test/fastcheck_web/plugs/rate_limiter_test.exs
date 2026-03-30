defmodule FastCheckWeb.Plugs.RateLimiterTest do
  use FastCheckWeb.ConnCase

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token
  alias FastCheck.Repo

  setup do
    # Clear rate limiter storage before tests
    clear_rate_limiter_storage()
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
    assert get_resp_header(conn_two, "x-ratelimit-limit") == []
    assert get_resp_header(conn_two, "x-ratelimit-remaining") == []
    assert Enum.join(get_resp_header(conn_two, "content-type"), ",") =~ "application/json"

    assert %{
             "error" => "rate_limited",
             "message" => "Too many requests. Please wait and try again.",
             "retry_after" => retry_after
           } = json_response(conn_two, 429)

    assert retry_after >= 1
  end

  test "scan throttle is scoped by per-token identity for the same event", %{conn: conn} do
    previous = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    on_exit(fn ->
      Application.put_env(:fastcheck, FastCheck.RateLimiter, previous)
    end)

    Application.put_env(
      :fastcheck,
      FastCheck.RateLimiter,
      Keyword.merge(previous, scan_limit: 1)
    )

    event = insert_event("Rate Limit Same Event")
    {:ok, token_one} = Token.issue_scanner_token(event.id)
    {:ok, token_two} = Token.issue_scanner_token(event.id)

    conn_one =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.24")
      |> put_req_header("authorization", "Bearer #{token_one}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_one.status == 200

    conn_two =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", "203.0.113.25")
      |> put_req_header("authorization", "Bearer #{token_two}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_two.status == 200
  end

  test "mobile throttle responses stay consistent with default storage", %{conn: conn} do
    with_rate_limiter_config(
      fn ->
        assert_mobile_scan_throttle_response(conn, "198.51.100.50")
      end,
      scan_limit: 1,
      storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter},
      mobile_storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
    )
  end

  test "mobile throttle responses stay consistent with mobile storage override", %{conn: conn} do
    ensure_ets_storage_started(FastCheck.RateLimiter.MobileTest)

    with_rate_limiter_config(
      fn ->
        assert_mobile_scan_throttle_response(conn, "198.51.100.51")
      end,
      scan_limit: 1,
      storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter},
      mobile_storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter.MobileTest}
    )
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

  defp assert_mobile_scan_throttle_response(conn, forwarded_for) do
    event = insert_event("Rate Limit Backend Parity Event #{forwarded_for}")
    {:ok, token} = Token.issue_scanner_token(event.id)

    conn_one =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", forwarded_for)
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_one.status == 200
    assert get_resp_header(conn_one, "x-ratelimit-limit") == ["1"]
    assert get_resp_header(conn_one, "x-ratelimit-remaining") == ["0"]
    assert get_resp_header(conn_one, "x-ratelimit-reset") != []

    conn_two =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-forwarded-for", forwarded_for)
      |> put_req_header("authorization", "Bearer #{token}")
      |> post("/api/v1/mobile/scans", %{"scans" => []})

    assert conn_two.status == 429
    assert get_resp_header(conn_two, "retry-after") != []
    assert get_resp_header(conn_two, "x-ratelimit-limit") == []
    assert get_resp_header(conn_two, "x-ratelimit-remaining") == []

    assert %{
             "error" => "rate_limited",
             "message" => "Too many requests. Please wait and try again.",
             "retry_after" => retry_after
           } = json_response(conn_two, 429)

    assert retry_after >= 1
  end

  defp with_rate_limiter_config(fun, overrides) when is_function(fun, 0) and is_list(overrides) do
    previous = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    on_exit(fn ->
      Application.put_env(:fastcheck, FastCheck.RateLimiter, previous)
      clear_rate_limiter_storage()
    end)

    Application.put_env(:fastcheck, FastCheck.RateLimiter, Keyword.merge(previous, overrides))
    clear_rate_limiter_storage()
    fun.()
  end

  defp clear_rate_limiter_storage do
    config = Application.get_env(:fastcheck, FastCheck.RateLimiter, [])

    [Keyword.get(config, :storage), Keyword.get(config, :mobile_storage)]
    |> Enum.uniq()
    |> Enum.each(fn
      {PlugAttack.Storage.Ets, table_name} when is_atom(table_name) ->
        PlugAttack.Storage.Ets.clean(table_name)

      _other ->
        :ok
    end)
  end

  defp ensure_ets_storage_started(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        {:ok, _pid} = PlugAttack.Storage.Ets.start_link(name: name, clean_period: 60_000)
        :ok
    end
  end
end
