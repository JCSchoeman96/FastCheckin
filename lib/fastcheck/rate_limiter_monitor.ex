defmodule FastCheck.RateLimiterMonitor do
  @moduledoc """
  GenServer that monitors the ETS rate limiter table size and logs it periodically.

  This helps detect memory leaks or unusual patterns in rate limiting.
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
        Logger.info("Rate limiter stats",
          table: "FastCheck.RateLimiter",
          entries: size,
          memory_words: memory,
          memory_kb: div(memory * :erlang.system_info(:wordsize), 1024)
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
