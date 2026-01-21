defmodule FastCheck.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    cache_children =
      if Application.get_env(:fastcheck, :cache_enabled, true) do
        [FastCheck.Cache.CacheManager]
      else
        []
      end

    children =
      [
        FastCheckWeb.Telemetry,
        FastCheck.Repo,
        FastCheck.TickeraCircuitBreaker,
        FastCheck.Events.SyncState,
        {DNSCluster, query: Application.get_env(:fastcheck, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: FastCheck.PubSub},
        # Abuse tracking ETS table (MUST be before telemetry handlers attach)
        %{
          id: :fastcheck_abuse_tracking_table,
          start: {
            :ets,
            :new,
            [:fastcheck_abuse_tracking, [:public, :named_table, :set, {:write_concurrency, true}]]
          }
        },
        # Rate limiter storage (ETS table) - cleans up expired entries every 60 seconds
        {PlugAttack.Storage.Ets, name: FastCheck.RateLimiter, clean_period: 60_000},
        # Rate limiter monitor - logs ETS table stats every 5 minutes
        FastCheck.RateLimiterMonitor,
        # NEW: ETS L1 cache initialization task
        %{
          id: FastCheck.Cache.EtsInit,
          start: {Task, :start_link, [fn -> FastCheck.Cache.EtsLayer.init() end]},
          restart: :transient
        }
      ] ++ metrics_children() ++ cache_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FastCheck.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # NOW safe to attach telemetry handlers (tables guaranteed to exist)
    FastCheck.Telemetry.setup()

    {:ok, pid}
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FastCheckWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp metrics_children do
    if metrics_enabled?() do
      [
        {TelemetryMetricsPrometheus.Core,
         metrics: FastCheckWeb.Telemetry.metrics(),
         port: String.to_integer(System.get_env("METRICS_PORT", "9568")),
         plug_cowboy_opts: [ip: {127, 0, 0, 1}]}
      ]
    else
      []
    end
  end

  defp metrics_enabled? do
    dev_enabled? = Application.get_env(:fastcheck, :enable_metrics, false)

    env_flag =
      System.get_env("ENABLE_METRICS", "")
      |> String.downcase()
      |> then(&(&1 in ["1", "true", "yes"]))

    dev_enabled? || env_flag
  end
end
