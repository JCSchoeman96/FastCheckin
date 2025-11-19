defmodule FastCheck.Telemetry do
  @moduledoc """
  Centralized telemetry event handlers for FastCheck observability.

  Handles:
  - Rate limit violation tracking
  - High-frequency abuse detection
  - Automatic IP banning with rich metadata
  - Aggregated metrics
  - Manual operator interventions
  """

  require Logger

  @doc """
  Attaches all telemetry handlers. Called from application.ex start/2 AFTER supervision tree starts.
  """
  def setup do
    attach_rate_limit_handlers()
    :ok
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
    expired_count = :ets.select_delete(:fastcheck_abuse_tracking, [
      {{{:banned, :"$1"}, %{ban_until: :"$2"}},
       [{:<, :"$2", {:const, now}}],
       [true]}
    ])

    # Remove counter entries older than 5 minutes
    current_window = div(:erlang.system_time(:second), 60)
    old_window_threshold = current_window - 5

    old_counters_count = :ets.select_delete(:fastcheck_abuse_tracking, [
      {{{:abuse_counter, :"$1", :"$2"}, :"$3"},
       [{:<, :"$2", old_window_threshold}],
       [true]}
    ])

    # Remove ban history older than 7 days
    seven_days_ago = DateTime.add(now, -7 * 24 * 3600, :second)
    :ets.select_delete(:fastcheck_abuse_tracking, [
      {{{:ban_history, :"$1"}, :"$2"},
       [{:<, :"$2", seven_days_ago}],
       [true]}
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
    active_bans = :ets.select(:fastcheck_abuse_tracking, [
      {{{:banned, :"$1"}, %{ban_until: :"$2"}},
       [{:>=, :"$2", {:const, now}}],
       [:"$1"]}
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
