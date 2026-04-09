defmodule FastCheck.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

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
        FastCheck.AbuseTrackingTable,
        FastCheckWeb.Telemetry,
        FastCheck.Repo,
        FastCheck.TickeraCircuitBreaker,
        FastCheck.Events.SyncState,
        {DNSCluster, query: Application.get_env(:fastcheck, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: FastCheck.PubSub},
        FastCheck.Redis.Connection,
        {Oban, Application.fetch_env!(:fastcheck, Oban)},
        FastCheckWeb.Endpoint,
        # Rate limiter storage (ETS table) - cleans up expired entries every 60 seconds
        {PlugAttack.Storage.Ets, name: FastCheck.RateLimiter, clean_period: 60_000},
        # Rate limiter monitor - logs ETS table stats every 5 minutes
        FastCheck.RateLimiterMonitor,
        # ETS L1 cache table owner process (tables must be owned by a long-lived process)
        FastCheck.Cache.EtsOwner
      ] ++ metrics_children() ++ cache_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FastCheck.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # NOW safe to attach telemetry handlers (tables guaranteed to exist)
    FastCheck.Telemetry.setup()

    Logger.info("Mobile scan ingestion initialized on the authoritative runtime path")

    log_database_pooling_mode()

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

  defp log_database_pooling_mode do
    database_pooling = Application.get_env(:fastcheck, :database_pooling, [])
    oban_runtime = Application.get_env(:fastcheck, :oban_runtime, [])

    Logger.info(
      "Database pooling resolved: mode=#{Keyword.get(database_pooling, :mode, :direct)} " <>
        "prepare=#{Keyword.get(database_pooling, :prepare, :named)} " <>
        "oban_notifier=#{Keyword.get(oban_runtime, :notifier, :postgres)}"
    )

    if Keyword.get(database_pooling, :mode) == :pgbouncer_transaction and
         Keyword.get(oban_runtime, :notifier) == :pg and
         is_nil(Application.get_env(:fastcheck, :dns_cluster_query)) do
      Logger.warning(
        "Oban.Notifiers.PG is enabled without DNS_CLUSTER_QUERY. Verify the Railway " <>
          "deployment is single-node or cluster discovery is configured before production cutover."
      )
    end
  end
end
