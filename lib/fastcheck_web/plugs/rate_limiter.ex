defmodule FastCheckWeb.Plugs.RateLimiter do
  @moduledoc """
  Rate limiting plug using PlugAttack to protect FastCheck endpoints.

  ## Rate Limits (Configurable)

  **Tier 1 - Critical (Strictest):**
  - Sync operations: 3 per event per 5 minutes (configurable)
  - Occupancy refresh: 10 per event per minute (configurable)

  **Tier 2 - High Frequency (Moderate):**
  - Check-in/out: 30 per IP per minute (configurable)
  - QR validation: 50 per IP per minute (configurable)

  **Tier 3 - Read-Only (Lenient):**
  - Dashboard: 100 per IP per minute (configurable)

  ## Configuration

  Set environment variables to override defaults:
  - `RATE_LIMIT_SYNC` - Sync operations limit (default: 3)
  - `RATE_LIMIT_OCCUPANCY` - Occupancy limit (default: 10)
  - `RATE_LIMIT_CHECKIN` - Check-in limit (default: 30)
  - `RATE_LIMIT_SCAN` - Scan limit (default: 50)
  - `RATE_LIMIT_DASHBOARD` - Dashboard limit (default: 100)
  """

  use PlugAttack
  import Plug.Conn
  require Logger

  # ---------------------------------------------------------------------------
  # RATE LIMIT CONFIG (RUNTIME)
  #
  # IMPORTANT:
  # Do NOT use Application.compile_env/3 here.
  # These values are set in config/runtime.exs via env vars on Railway.
  # compile_env marks them as "compile-time" and releases will FAIL BOOT if
  # runtime.exs sets a different value (validate_compile_env).
  # ---------------------------------------------------------------------------

  defp get_limit(key, default) when is_atom(key) and is_integer(default) do
    :fastcheck
    |> Application.get_env(FastCheck.RateLimiter, [])
    |> Keyword.get(key, default)
    |> normalize_limit(default)
  end

  defp normalize_limit(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_limit(_value, default), do: default

  # Storage backend configured in application.ex
  # {PlugAttack.Storage.Ets, name: FastCheck.RateLimiter, clean_period: 60_000}

  # Don't rate limit localhost (development) - supports IPv4 and IPv6
  rule "allow_local", conn do
    case get_peer_ip(conn) do
      # IPv4 localhost
      "127.0.0.1" -> {:allow, :localhost}
      # IPv6 localhost
      "::1" -> {:allow, :localhost}
      _ -> nil
    end
  end

  # Block auto-banned IPs (high-frequency abusers)
  rule "block_auto_banned", conn do
    ip = get_peer_ip(conn)

    case :ets.lookup(:fastcheck_abuse_tracking, {:banned, ip}) do
      [{_, ban_info}] when is_map(ban_info) ->
        if DateTime.compare(DateTime.utc_now(), ban_info.ban_until) == :lt do
          # Ban still active - return ban metadata
          Logger.warning("Auto-banned IP attempted access",
            ip: ip,
            ban_until: ban_info.ban_until,
            reason: ban_info.reason,
            path: conn.request_path
          )

          {:block, {:auto_banned, ban_info}}
        else
          # Ban expired - clean up and allow
          :ets.delete(:fastcheck_abuse_tracking, {:banned, ip})
          nil
        end

      _ ->
        # Not banned or old format
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # Tier 1: Critical operations (Tickera API + expensive DB queries)
  rule "throttle_sync", conn do
    if sync_operation?(conn) do
      key = "sync:#{get_event_id(conn)}:#{get_peer_ip(conn)}"
      # Configurable limit per 5 minutes per event
      throttle(key,
        limit: get_limit(:sync_limit, 3),
        period: 300_000,
        storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
      )
    else
      nil
    end
  end

  rule "throttle_occupancy", conn do
    if occupancy_operation?(conn) do
      key = "occupancy:#{get_event_id(conn)}:#{get_peer_ip(conn)}"
      # Configurable limit per minute per event
      throttle(key,
        limit: get_limit(:occupancy_limit, 10),
        period: 60_000,
        storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
      )
    else
      nil
    end
  end

  # Tier 1.5: Security critical (Login)
  rule "throttle_login", conn do
    if login_operation?(conn) do
      key = "login:#{get_peer_ip(conn)}"
      # Strict limit per minute per IP to prevent brute force
      throttle(key,
        limit: get_limit(:login_limit, 5),
        period: 60_000,
        storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
      )
    else
      nil
    end
  end

  # Tier 2: High frequency scanner operations
  rule "throttle_check_in", conn do
    if check_in_operation?(conn) do
      key = "check_in:#{get_peer_ip(conn)}"
      # Configurable limit per minute per IP
      throttle(key,
        limit: get_limit(:checkin_limit, 30),
        period: 60_000,
        storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
      )
    else
      nil
    end
  end

  rule "throttle_scan", conn do
    if scan_operation?(conn) do
      key = "scan:#{get_peer_ip(conn)}"
      # Configurable limit per minute per IP
      throttle(key,
        limit: get_limit(:scan_limit, 50),
        period: 60_000,
        storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
      )
    else
      nil
    end
  end

  # Tier 3: General dashboard/read operations (lenient)
  rule "throttle_dashboard", conn do
    key = "general:#{get_peer_ip(conn)}"
    # Configurable limit per minute per IP
    throttle(key,
      limit: get_limit(:dashboard_limit, 100),
      period: 60_000,
      storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}
    )
  end

  # Handle rate limit exceeded - log and prepare response
  def allow_action(conn, {:throttle, data}, _opts) do
    retry_after = div(data.period, 1000)

    # Enhanced logging with more context
    Logger.warning("Rate limit exceeded",
      ip: get_peer_ip(conn),
      path: conn.request_path,
      limit: data.limit,
      period: data.period,
      event_id: get_event_id(conn),
      user_agent: get_user_agent(conn)
    )

    conn
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_rate_limit_response()
  end

  def allow_action(conn, _data, _opts), do: conn

  # Block rate limited requests
  def block_action(conn, {:auto_banned, ban_info}, _opts) when is_map(ban_info) do
    # Auto-ban with metadata
    retry_after = DateTime.diff(ban_info.ban_until, DateTime.utc_now())

    conn
    |> put_status(429)
    |> put_resp_header("retry-after", to_string(max(retry_after, 1)))
    |> put_resp_header("x-ban-reason", ban_info.reason)
    |> send_auto_ban_response(ban_info)
    |> halt()
  end

  def block_action(conn, {:throttle, data}, _opts) do
    retry_after = div(data.period, 1000)

    # Emit telemetry event BEFORE halting (non-blocking)
    :telemetry.execute(
      [:fastcheck, :rate_limit, :blocked],
      %{count: 1},
      %{
        path: conn.request_path,
        ip: get_peer_ip(conn),
        limit: data.limit,
        period: data.period,
        event_id: get_event_id(conn)
      }
    )

    # Enhanced logging with more context
    Logger.warning("Rate limit blocked request",
      ip: get_peer_ip(conn),
      path: conn.request_path,
      limit: data.limit,
      period: data.period,
      event_id: get_event_id(conn),
      user_agent: get_user_agent(conn)
    )

    conn
    |> put_status(429)
    |> put_resp_header("retry-after", to_string(retry_after))
    |> send_rate_limit_response()
    |> halt()
  end

  def block_action(conn, _data, _opts), do: conn

  # Helper: Detect operation types
  defp sync_operation?(conn) do
    conn.request_path =~ ~r{/events/\d+/sync} or
      conn.request_path =~ ~r{/api/v1/mobile/attendees}
  end

  defp occupancy_operation?(conn) do
    conn.request_path =~ ~r/\/events\/\d+\/occupancy/ or
      conn.request_path =~ ~r/\/dashboard\/occupancy/
  end

  defp login_operation?(conn) do
    conn.request_path == "/login" or
      conn.request_path == "/api/v1/mobile/login"
  end

  defp check_in_operation?(conn) do
    conn.request_path =~ ~r/\/(check_in|check_out|check-in|check-out)/
  end

  defp scan_operation?(conn) do
    conn.request_path =~ ~r/\/scan/ or conn.request_path =~ ~r/\/validate_ticket/
  end

  # Helper: Extract event ID from path or params
  defp get_event_id(conn) do
    cond do
      is_integer(conn.assigns[:current_event_id]) ->
        conn.assigns[:current_event_id]

      is_map(conn.assigns[:token_claims]) ->
        conn.assigns[:token_claims]["event_id"]

      match = Regex.run(~r/\/events\/(\d+)/, conn.request_path) ->
        [_full, id] = match
        id

      true ->
        conn.params["event_id"] || "unknown"
    end
  end

  # Helper: Get peer IP address (handles proxies and IPv6)
  defp get_peer_ip(conn) do
    # Check for proxy headers first (Cloudflare, nginx, etc.)
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        # x-forwarded-for may contain multiple IPs, take the first
        ip |> String.split(",") |> List.first() |> String.trim()

      _ ->
        # Fallback to direct connection IP (handles IPv4 and IPv6)
        case Plug.Conn.get_peer_data(conn) do
          %{address: address} -> :inet.ntoa(address) |> to_string()
          _ -> "unknown"
        end
    end
  end

  # Helper: Get user agent (truncated to prevent log bloat)
  defp get_user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      # Truncate to 100 chars
      [ua | _] -> String.slice(ua, 0, 100)
      _ -> "unknown"
    end
  end

  # Helper: Check if IP is currently auto-banned

  # Helper: Send appropriate error response based on request type
  defp send_rate_limit_response(conn) do
    retry_after = get_resp_header(conn, "retry-after") |> List.first() || "60"

    cond do
      json_request?(conn) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "rate_limited",
            message: "Too many requests. Please wait and try again.",
            retry_after: String.to_integer(retry_after)
          })
        )

      live_view_request?(conn) ->
        # LiveView will handle via flash message in controller
        conn
        |> Phoenix.Controller.put_flash(
          :error,
          "Too many requests. Please wait before trying again."
        )
        |> Phoenix.Controller.redirect(to: "/")

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Rate limit exceeded. Retry after #{retry_after} seconds.")
    end
  end

  defp json_request?(conn) do
    case get_req_header(conn, "accept") do
      [] -> false
      [accept | _] -> String.contains?(accept, "application/json")
    end
  end

  defp live_view_request?(conn) do
    conn.private[:phoenix_live_view] != nil or
      (conn.request_path =~ ~r/^\/live\// or
         get_req_header(conn, "x-requested-with") == ["live-view"])
  end

  # Send auto-ban specific responses with ban metadata
  defp send_auto_ban_response(conn, ban_info) do
    retry_after = DateTime.diff(ban_info.ban_until, DateTime.utc_now())

    cond do
      json_request?(conn) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          429,
          Jason.encode!(%{
            error: "auto_banned",
            message: "Your IP has been temporarily banned due to abuse.",
            reason: ban_info.reason,
            ban_until: DateTime.to_iso8601(ban_info.ban_until),
            retry_after: max(retry_after, 1),
            ban_count: ban_info.ban_count
          })
        )

      live_view_request?(conn) ->
        conn
        |> Phoenix.Controller.put_flash(
          :error,
          "Access temporarily blocked. Reason: #{ban_info.reason}"
        )
        |> Phoenix.Controller.redirect(to: "/")

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          429,
          "Access blocked. Reason: #{ban_info.reason}. Retry after #{ban_info.ban_until}"
        )
    end
  end
end
