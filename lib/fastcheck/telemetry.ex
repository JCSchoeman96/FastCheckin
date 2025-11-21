defmodule FastCheck.Telemetry do
  @moduledoc """
  Centralized telemetry event handlers for FastCheck observability.

  Handles:
  - Phoenix endpoint metrics (request rates, durations, failures)
  - Phoenix router dispatch metrics
  - Database query performance monitoring
  - Rate limit violation tracking
  - High-frequency abuse detection
  - Automatic IP banning with rich metadata
  - Aggregated metrics for monitoring systems
  """

  require Logger

  @doc """
  Attaches all telemetry handlers. Called from application.ex start/2 AFTER supervision tree starts.
  """
  def setup do
    attach_phoenix_handlers()
    attach_rate_limit_handlers()
    attach_slow_query_handler()
    :ok
  end

  defp attach_phoenix_handlers do
    # Track Phoenix endpoint metrics (request count, duration, errors)
    :telemetry.attach(
      "fastcheck-phoenix-endpoint",
      [:phoenix, :endpoint, :stop],
      &handle_phoenix_endpoint/4,
      %{}
    )

    # Track router dispatch metrics
    :telemetry.attach(
      "fastcheck-phoenix-router",
      [:phoenix, :router_dispatch, :stop],
      &handle_router_dispatch/4,
      %{}
    )

    # Track Phoenix errors/exceptions
    :telemetry.attach(
      "fastcheck-phoenix-router-exception",
      [:phoenix, :router_dispatch, :exception],
      &handle_router_exception/4,
      %{}
    )
  end

  defp attach_slow_query_handler do
    # Monitor slow database queries
    :telemetry.attach(
      "fastcheck-slow-query-logger",
      [:fastcheck, :repo, :query],
      &handle_slow_query/4,
      %{}
    )
  end

  defp attach_rate_limit_handlers do
    # Track aggregate rate limit metrics
    :telemetry.attach(
      "fastcheck-rate-limit-counter",
      [:fastcheck, :rate_limit, :blocked],
      &handle_rate_limit_blocked/4,
      %{}
    )

    # Detect and auto-ban high-frequency abusers
    :telemetry.attach(
      "fastcheck-rate-limit-abuse-detector",
      [:fastcheck, :rate_limit, :blocked],
      &handle_abuse_detection/4,
      %{}
    )
  end

  @doc """
  Handles rate limit blocked events.

  Emits aggregate metrics that can be consumed by monitoring systems.
  """
  def handle_rate_limit_blocked(_event, measurements, metadata, _config) do
    # Emit aggregate metric for monitoring dashboards
    :telemetry.execute(
      [:fastcheck, :rate_limit, :total],
      %{count: measurements.count},
      Map.take(metadata, [:path, :limit, :period])
    )
  end

  @doc """
  Logs slow database queries that exceed configured thresholds.

  Thresholds:
  - Warning: 100ms (configurable via SLOW_QUERY_WARNING_MS)
  - Critical: 500ms (configurable via SLOW_QUERY_CRITICAL_MS)
  """
  def handle_slow_query(_event, measurements, metadata, _config) do
    # Get thresholds from environment (in milliseconds)
    warning_threshold =
      System.get_env("SLOW_QUERY_WARNING_MS", "100")
      |> String.to_integer()
      |> Kernel.*(1000)

    critical_threshold =
      System.get_env("SLOW_QUERY_CRITICAL_MS", "500")
      |> String.to_integer()
      |> Kernel.*(1000)

    # Query time is in native units, convert to microseconds
    query_time_us = System.convert_time_unit(measurements.query_time, :native, :microsecond)

    cond do
      query_time_us >= critical_threshold ->
        Logger.error("CRITICAL: Slow database query detected",
          query_time_ms: div(query_time_us, 1000),
          query: truncate_query(metadata[:query]),
          source: metadata[:source],
          result: metadata[:result]
        )

        # Emit telemetry for alerting
        :telemetry.execute(
          [:fastcheck, :repo, :slow_query_critical],
          %{count: 1, duration_us: query_time_us},
          metadata
        )

      query_time_us >= warning_threshold ->
        Logger.warning("Slow database query detected",
          query_time_ms: div(query_time_us, 1000),
          query: truncate_query(metadata[:query]),
          source: metadata[:source]
        )

        # Emit telemetry for metrics
        :telemetry.execute(
          [:fastcheck, :repo, :slow_query_warning],
          %{count: 1, duration_us: query_time_us},
          metadata
        )

      true ->
        :ok
    end
  end

  # Truncate long queries for logging
  defp truncate_query(nil), do: "N/A"

  defp truncate_query(query) when is_binary(query) do
    max_length = 200

    if String.length(query) > max_length do
      String.slice(query, 0, max_length) <> "..."
    else
      query
    end
  end

  @doc """
  Handles Phoenix endpoint stop events to track request metrics.

  Emits metrics for:
  - Request duration
  - HTTP status codes
  - Request counts per route
  """
  def handle_phoenix_endpoint(_event, measurements, metadata, _config) do
    # Convert duration to milliseconds
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    # Emit aggregate metrics for monitoring
    :telemetry.execute(
      [:fastcheck, :phoenix, :request],
      %{
        duration: measurements.duration,
        count: 1
      },
      %{
        status: metadata[:status] || 200,
        method: metadata[:method] || "UNKNOWN",
        route: metadata[:route] || metadata[:request_path] || "unknown"
      }
    )

    # Log slow requests (> 5 seconds)
    if duration_ms > 5_000 do
      Logger.warning("Slow HTTP request detected",
        duration_ms: duration_ms,
        method: metadata[:method],
        path: metadata[:request_path],
        status: metadata[:status]
      )
    end
  end

  @doc """
  Handles Phoenix router dispatch stop events for route-level metrics.
  """
  def handle_router_dispatch(_event, measurements, metadata, _config) do
    :telemetry.execute(
      [:fastcheck, :phoenix, :route_dispatch],
      %{
        duration: measurements.duration,
        count: 1
      },
      %{
        route: metadata[:route] || "unknown",
        plug: metadata[:plug] || "unknown",
        plug_opts: inspect(metadata[:plug_opts])
      }
    )
  end

  @doc """
  Handles Phoenix router exception events to track failures.
  """
  def handle_router_exception(_event, measurements, metadata, _config) do
    Logger.error("Request exception",
      kind: metadata[:kind],
      reason: Exception.message(metadata[:reason]),
      route: metadata[:route],
      plug: metadata[:plug]
    )

    :telemetry.execute(
      [:fastcheck, :phoenix, :exception],
      %{count: 1, duration: measurements[:duration] || 0},
      %{
        kind: metadata[:kind],
        route: metadata[:route] || "unknown",
        plug: metadata[:plug] || "unknown"
      }
    )
  end

  @doc """
  Detects high-frequency abuse patterns and automatically bans repeat offenders.

  Tracks blocks per IP in a 60-second sliding window. IPs exceeding the threshold
  are automatically banned for 1 hour with rich metadata.
  """
  def handle_abuse_detection(_event, _measurements, metadata, _config) do
    # Get configuration
    config = Application.get_env(:fastcheck, :rate_limit_alerts, [])
    threshold = Keyword.get(config, :abuse_threshold, 10)
    window_seconds = Keyword.get(config, :abuse_window_seconds, 60)

    # Track blocks per IP in ETS with time-based key
    table = :fastcheck_abuse_tracking
    window_key = div(:erlang.system_time(:second), window_seconds)
    counter_key = {:abuse_counter, metadata.ip, window_key}

    # Increment counter for this IP in current window
    case :ets.update_counter(table, counter_key, {2, 1}, {counter_key, 0}) do
      count when count >= threshold ->
        # High-frequency abuse detected - auto-ban for 1 hour
        ban_until = DateTime.add(DateTime.utc_now(), 3600, :second)

        # Store rich ban metadata (not just DateTime)
        ban_info = %{
          ban_until: ban_until,
          reason: "#{count} blocks in #{window_seconds}s (threshold: #{threshold})",
          trigger_path: metadata.path,
          trigger_event_id: metadata[:event_id] || "unknown",
          banned_at: DateTime.utc_now(),
          ban_count: get_previous_ban_count(metadata.ip) + 1
        }

        ban_key = {:banned, metadata.ip}
        :ets.insert(table, {ban_key, ban_info})

        # Update ban count history
        :ets.insert(table, {{:ban_history, metadata.ip}, ban_info.ban_count})

        Logger.error("IP auto-banned for high-frequency abuse",
          ip: metadata.ip,
          blocks: count,
          ban_until: DateTime.to_iso8601(ban_until),
          ban_count: ban_info.ban_count,
          reason: ban_info.reason,
          trigger_path: ban_info.trigger_path
        )

        # Emit telemetry for alerting systems
        :telemetry.execute(
          [:fastcheck, :rate_limit, :auto_ban],
          %{count: 1},
          Map.merge(metadata, %{ban_until: ban_until, ban_info: ban_info})
        )

      count when count in [5, 8] ->
        # Warning threshold (50% and 80% of ban threshold)
        Logger.warning("High rate limit violations detected",
          ip: metadata.ip,
          blocks_per_minute: count,
          threshold: threshold,
          status: "monitoring"
        )

      _ ->
        :ok
    end
  end

  @doc """
  Removes expired ban entries and old counter entries.

  Called periodically by RateLimiterMonitor every 5 minutes.
  """
  def cleanup_expired_bans do
    now = DateTime.utc_now()

    # Remove expired bans (comparing DateTime in map)
    expired_count =
      :ets.select_delete(:fastcheck_abuse_tracking, [
        {{{:banned, :"$1"}, %{ban_until: :"$2"}}, [{:<, :"$2", {:const, now}}], [true]}
      ])

    # Remove counter entries older than 5 minutes
    current_window = div(:erlang.system_time(:second), 60)
    old_window_threshold = current_window - 5

    old_counters_count =
      :ets.select_delete(:fastcheck_abuse_tracking, [
        {{{:abuse_counter, :"$1", :"$2"}, :"$3"}, [{:<, :"$2", old_window_threshold}], [true]}
      ])

    # Remove ban history older than 7 days
    seven_days_ago = DateTime.add(now, -7 * 24 * 3600, :second)

    :ets.select_delete(:fastcheck_abuse_tracking, [
      {{{:ban_history, :"$1"}, :"$2"}, [{:<, :"$2", seven_days_ago}], [true]}
    ])

    if expired_count > 0 or old_counters_count > 0 do
      Logger.debug("Abuse tracking cleanup",
        expired_bans: expired_count,
        old_counters: old_counters_count
      )
    end
  end

  @doc """
  Gets current abuse statistics for dashboard display.
  """
  def get_abuse_stats do
    now = DateTime.utc_now()

    # Active bans (not expired)
    active_bans =
      :ets.select(:fastcheck_abuse_tracking, [
        {{{:banned, :"$1"}, %{ban_until: :"$2"}}, [{:>=, :"$2", {:const, now}}], [:"$1"]}
      ])

    # Top violators in current window
    current_window = div(:erlang.system_time(:second), 60)

    top_violators =
      :ets.select(:fastcheck_abuse_tracking, [
        {{{:abuse_counter, :"$1", current_window}, :"$2"}, [], [{{:"$1", :"$2"}}]}
      ])
      |> Enum.sort_by(fn {_ip, count} -> count end, :desc)
      |> Enum.take(10)

    %{
      active_bans: length(active_bans),
      banned_ips: active_bans,
      top_violators: top_violators,
      total_tracking_entries: :ets.info(:fastcheck_abuse_tracking, :size) || 0
    }
  end

  @doc """
  Manually unban an IP address. Use for false positives or operator intervention.

  Returns `{:ok, message}` on success or `{:error, reason}` if IP not banned.
  """
  def unban_ip(ip) when is_binary(ip) do
    case :ets.take(:fastcheck_abuse_tracking, {:banned, ip}) do
      [{_, ban_info}] when is_map(ban_info) ->
        Logger.warning("IP manually unbanned by operator",
          ip: ip,
          previous_ban_until: ban_info.ban_until,
          ban_reason: ban_info.reason,
          operator: true
        )

        # Also clear any active counters for this IP
        current_window = div(:erlang.system_time(:second), 60)
        :ets.delete(:fastcheck_abuse_tracking, {:abuse_counter, ip, current_window})

        {:ok, "IP #{ip} unbanned successfully"}

      [] ->
        {:error, "IP #{ip} is not currently banned"}
    end
  end

  # Track how many times an IP has been banned (for escalation)
  defp get_previous_ban_count(ip) do
    case :ets.lookup(:fastcheck_abuse_tracking, {:ban_history, ip}) do
      [{_, count}] when is_integer(count) -> count
      _ -> 0
    end
  end
end
