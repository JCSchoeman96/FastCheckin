defmodule FastCheck.RateLimiterMonitor do
  @moduledoc """
  GenServer that monitors the ETS rate limiter table size and logs it periodically.

  This helps detect memory leaks or unusual patterns in rate limiting.
  Also performs cleanup of expired ban entries.
  """

  use GenServer
  require Logger

  @check_interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    # Schedule first check after initialization
    schedule_check()
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    # Get ETS table stats
    case :ets.info(FastCheck.RateLimiter, :size) do
      :undefined ->
        Logger.warning("Rate limiter ETS table not found")

      size ->
        memory = :ets.info(FastCheck.RateLimiter, :memory)
        memory_kb = div(memory * :erlang.system_info(:wordsize), 1024)

        # Get alert threshold from config
        config = Application.get_env(:fastcheck, :rate_limit_alerts, [])
        threshold = Keyword.get(config, :ets_size_alert_threshold, 1000)

        # Alert if size exceeds threshold
        if size > threshold do
          Logger.error("Rate limiter ETS table exceeds threshold",
            entries: size,
            threshold: threshold,
            memory_kb: memory_kb,
            action_required: "investigate memory leak or increase cleanup frequency"
          )
        else
          Logger.info("Rate limiter stats",
            table: "FastCheck.RateLimiter",
            entries: size,
            memory_kb: memory_kb
          )
        end
    end

    # Cleanup expired bans and old counters
    FastCheck.Telemetry.cleanup_expired_bans()

    # Log abuse tracking stats
    abuse_stats = FastCheck.Telemetry.get_abuse_stats()

    if abuse_stats.active_bans > 0 do
      Logger.info("Abuse tracking stats",
        active_bans: abuse_stats.active_bans,
        top_violators_count: length(abuse_stats.top_violators)
      )
    end

    # Schedule next check
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end
end
