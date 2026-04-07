import Config

# ENCRYPTION_KEY is used by FastCheck.Crypto for field-level encryption.
# Required if you encrypt attendee PII; safe to skip for MVP scanning.
encryption_key =
  case System.get_env("ENCRYPTION_KEY") do
    nil ->
      if config_env() == :prod do
        raise """
        environment variable ENCRYPTION_KEY is missing.
        Generate one with: mix phx.gen.secret
        """
      else
        "dev fastcheck encryption key dev fastcheck encryption key"
      end

    value ->
      String.trim(value)
  end

if config_env() == :prod and byte_size(encryption_key) < 32 do
  raise """
  ENCRYPTION_KEY must be at least 32 bytes in production.
  Generate one with: mix phx.gen.secret
  """
end

config :fastcheck, :encryption_key, encryption_key

mobile_token_secret =
  case System.get_env("MOBILE_JWT_SECRET") do
    nil ->
      if config_env() == :prod do
        raise """
        environment variable MOBILE_JWT_SECRET is missing.
        Generate a strong shared secret and export it before booting FastCheck.
        """
      else
        "dev fastcheck mobile jwt secret key"
      end

    value ->
      String.trim(value)
  end

if config_env() == :prod and byte_size(mobile_token_secret) < 32 do
  raise """
  MOBILE_JWT_SECRET must be at least 32 bytes in production.
  Generate one with: mix phx.gen.secret
  """
end

config :fastcheck, FastCheck.Mobile.Token,
  secret_key: mobile_token_secret,
  token_ttl_seconds: String.to_integer(System.get_env("MOBILE_JWT_TTL_SECONDS") || "86400"),
  issuer: System.get_env("MOBILE_JWT_ISSUER") || "fastcheck",
  algorithm: System.get_env("MOBILE_JWT_ALGORITHM") || "HS256"

# LiveDashboard is only mounted in dev routes, so dashboard auth is optional.
# If you enable it in prod, set DASHBOARD_USERNAME and DASHBOARD_PASSWORD.
dashboard_username = System.get_env("DASHBOARD_USERNAME") || "admin"
dashboard_password = System.get_env("DASHBOARD_PASSWORD") || "fastcheck"

config :fastcheck, :dashboard_auth, %{
  username: dashboard_username,
  password: dashboard_password
}

default_tickera_site_url =
  case System.get_env("DEFAULT_TICKERA_SITE_URL", "https://voelgoed.co.za") do
    nil ->
      "https://voelgoed.co.za"

    value ->
      case String.trim(value) do
        "" -> "https://voelgoed.co.za"
        trimmed -> trimmed
      end
  end

config :fastcheck, :default_tickera_site_url, default_tickera_site_url

# Cache defaults shared across all environments. The values can be overridden
# via environment variables without recompiling the release.
cache_enabled = System.get_env("CACHE_ENABLED", "true") == "true"

cache_ttl = [
  ticket_config: :timer.hours(1),
  event_metadata: :timer.hours(6),
  occupancy: :timer.seconds(10)
]

default_redis_url =
  cond do
    System.get_env("GITHUB_ACTIONS") ->
      "redis://localhost:6379"

    config_env() == :prod ->
      "redis://localhost:6379"

    true ->
      # Local Docker compose publishes the Redis container on host port 6380.
      "redis://localhost:6380"
  end

redis_url = System.get_env("REDIS_URL", default_redis_url)

config :fastcheck,
  cache_enabled: cache_enabled,
  cache_ttl: cache_ttl,
  redis_url: redis_url

mobile_scan_ingestion_mode =
  "MOBILE_SCAN_INGESTION_MODE"
  |> System.get_env("legacy")
  |> FastCheck.Scans.IngestionMode.resolve()

mobile_scan_force_enqueue_failure =
  case System.get_env("MOBILE_SCAN_FORCE_ENQUEUE_FAILURE", "false")
       |> String.trim()
       |> String.downcase() do
    value when value in ["1", "true", "yes", "on"] -> true
    _ -> false
  end

config :fastcheck, :mobile_scan_ingestion,
  mode: mobile_scan_ingestion_mode,
  chunk_size: String.to_integer(System.get_env("MOBILE_SCAN_CHUNK_SIZE") || "100"),
  live_namespace: System.get_env("MOBILE_SCAN_LIVE_NAMESPACE", "live"),
  shadow_namespace: System.get_env("MOBILE_SCAN_SHADOW_NAMESPACE", "shadow"),
  force_enqueue_failure: mobile_scan_force_enqueue_failure

# Scanner runtime tuning for launch performance.
config :fastcheck, :scanner_performance,
  stats_reconcile_ms: String.to_integer(System.get_env("SCANNER_STATS_RECONCILE_MS") || "30000"),
  force_refresh_every_n_scans:
    String.to_integer(System.get_env("SCANNER_FORCE_REFRESH_EVERY_N_SCANS") || "20"),
  warmup_on_login:
    (System.get_env("SCANNER_WARMUP_ON_LOGIN", "true")
     |> String.trim()
     |> String.downcase()) in ["1", "true", "yes", "on"],
  scanning_allowed_cache_ttl_ms:
    String.to_integer(System.get_env("SCANNER_SCANNING_ALLOWED_TTL_MS") || "5000")

# Mobile sync runtime tuning for launch performance.
config :fastcheck, :mobile_sync_performance,
  parallel:
    (System.get_env("MOBILE_SYNC_PARALLEL", "true")
     |> String.trim()
     |> String.downcase()) in ["1", "true", "yes", "on"],
  max_concurrency: String.to_integer(System.get_env("MOBILE_SYNC_MAX_CONCURRENCY") || "16"),
  task_timeout_ms: String.to_integer(System.get_env("MOBILE_SYNC_TASK_TIMEOUT_MS") || "10000")

allow_unknown_payment_status =
  case System.get_env("ALLOW_UNKNOWN_PAYMENT_STATUS", "false")
       |> String.trim()
       |> String.downcase() do
    value when value in ["1", "true", "yes", "on"] -> true
    _ -> false
  end

config :fastcheck, :allow_unknown_payment_status, allow_unknown_payment_status

database_pooling_mode =
  case System.get_env("DATABASE_POOLING_MODE", "direct")
       |> String.trim()
       |> String.downcase() do
    "pgbouncer_transaction" -> :pgbouncer_transaction
    "pgbouncer_session" -> :pgbouncer_session
    _ -> :direct
  end

database_prepare_mode =
  case System.get_env("DB_PREPARE_MODE") do
    nil ->
      case database_pooling_mode do
        :pgbouncer_transaction -> :unnamed
        _ -> :named
      end

    value ->
      case String.trim(value) |> String.downcase() do
        "unnamed" -> :unnamed
        _ -> :named
      end
  end

oban_notifier_name =
  case System.get_env("OBAN_NOTIFIER") do
    nil ->
      case database_pooling_mode do
        :pgbouncer_transaction -> :pg
        _ -> :postgres
      end

    value ->
      case String.trim(value) |> String.downcase() do
        "pg" -> :pg
        _ -> :postgres
      end
  end

oban_notifier =
  case oban_notifier_name do
    :pg -> {Oban.Notifiers.PG, []}
    :postgres -> {Oban.Notifiers.Postgres, []}
  end

if config_env() == :prod and database_pooling_mode == :pgbouncer_transaction and
     oban_notifier_name == :postgres do
  raise """
  OBAN_NOTIFIER=postgres is not safe with DATABASE_POOLING_MODE=pgbouncer_transaction.
  Use OBAN_NOTIFIER=pg or keep the shared Repo on direct Postgres for this rollout.
  """
end

config :fastcheck, :database_pooling,
  mode: database_pooling_mode,
  prepare: database_prepare_mode

config :fastcheck, :oban_runtime, notifier: oban_notifier_name
config :fastcheck, Oban, notifier: oban_notifier

# config/runtime.exs is executed for all environments and is the right place to
# read secrets that should not be baked into the release.
# Note: PHX_SERVER is not needed — the prod block below sets server: true.

if config_env() == :prod do
  # ---------------------------------------------------------------------------
  # Database
  # ---------------------------------------------------------------------------
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      Provide the full Ecto URL (ecto://USER:PASS@HOST:PORT/DB) for releases.
      """

    allow_local_db_in_prod? =
      case System.get_env("ALLOW_LOCAL_DB_IN_PROD", "false") |> String.trim() |> String.downcase() do
        value when value in ["1", "true", "yes", "on"] -> true
        _ -> false
      end

    database_host = URI.parse(database_url).host

    if database_host in ["localhost", "127.0.0.1", "::1"] and not allow_local_db_in_prod? do
      raise """
      DATABASE_URL points to #{database_host}, which is blocked by default in production.

      Set ALLOW_LOCAL_DB_IN_PROD=true for single-VPS deployments that intentionally use
      local Postgres/PgBouncer.
      """
    end

  # Railway (and many managed Postgres hosts) require SSL. Default to true but
  # allow operators to opt out via DATABASE_SSL=false when the host doesn't
  # support it or the URL already encodes sslmode.
  ssl? = System.get_env("DATABASE_SSL", "true") in ~w(true 1)

  config :fastcheck, FastCheck.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    ssl: ssl?,
    prepare: database_prepare_mode,
    queue_target: 5_000,
    queue_interval: 1_000,
    timeout: String.to_integer(System.get_env("DB_TIMEOUT_MS") || "30000"),
    log: false,
    telemetry_prefix: [:fastcheck, :repo]

  # ---------------------------------------------------------------------------
  # Secrets
  # ---------------------------------------------------------------------------
  secret_key_base =
    case System.get_env("SECRET_KEY_BASE") do
      nil ->
        raise """
        environment variable SECRET_KEY_BASE is missing.
        Generate one with: mix phx.gen.secret
        """

      value ->
        String.trim(value)
    end

  if byte_size(secret_key_base) < 64 do
    raise """
    SECRET_KEY_BASE must be at least 64 bytes in production.
    Generate one with: mix phx.gen.secret
    """
  end

  # ---------------------------------------------------------------------------
  # Endpoint
  # ---------------------------------------------------------------------------
  domain = System.get_env("DOMAIN") || System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  dashboard_origin = "https://#{domain}"

  cors_origins =
    [dashboard_origin]
    |> Enum.reject(&is_nil/1)

  config :fastcheck, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fastcheck, FastCheckWeb.Endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: port],
    url: [host: domain, scheme: "https", port: 443],
    check_origin: ["https://#{domain}"],
    secret_key_base: secret_key_base,
    # Railway (and most PaaS) terminate TLS at the proxy layer and forward
    # X-Forwarded-Proto. force_ssl ensures Phoenix generates https:// URLs and
    # sets secure cookie flags.
    force_ssl: [hsts: true, rewrite_on: [:x_forwarded_proto]],
    cors_origins: cors_origins,
    session_options: [secure: true]
end

# Runtime configurable rate limiting
# Override defaults via environment variables for production tuning without recompilation.
# RATE_LIMIT_BACKEND controls where counters are stored:
# - single-node (default): all rules in ETS
# - multi-node: mobile login/sync/scan rules in shared backend, others remain ETS
rate_limit_backend_mode =
  case System.get_env("RATE_LIMIT_BACKEND", "single-node")
       |> String.trim()
       |> String.downcase() do
    "multi-node" -> :multi_node
    _ -> :single_node
  end

default_rate_limit_storage = {PlugAttack.Storage.Ets, FastCheck.RateLimiter}

mobile_rate_limit_storage =
  case rate_limit_backend_mode do
    :single_node ->
      default_rate_limit_storage

    :multi_node ->
      case System.get_env("RATE_LIMIT_SHARED_BACKEND", "redis")
           |> String.trim()
           |> String.downcase() do
        "redis" -> {PlugAttack.Storage.Redis, FastCheck.Redix}
        _ -> default_rate_limit_storage
      end
  end

config :fastcheck, FastCheck.RateLimiter,
  storage: default_rate_limit_storage,
  mobile_storage: mobile_rate_limit_storage,
  backend_mode: rate_limit_backend_mode,
  sync_limit: String.to_integer(System.get_env("RATE_LIMIT_SYNC") || "3"),
  sync_period: 300_000,
  occupancy_limit: String.to_integer(System.get_env("RATE_LIMIT_OCCUPANCY") || "10"),
  occupancy_period: 60_000,
  checkin_limit: String.to_integer(System.get_env("RATE_LIMIT_CHECKIN") || "200"),
  checkin_period: 60_000,
  scan_limit: String.to_integer(System.get_env("RATE_LIMIT_SCAN") || "400"),
  scan_period: 60_000,
  dashboard_limit: String.to_integer(System.get_env("RATE_LIMIT_DASHBOARD") || "100"),
  dashboard_period: 60_000

# Alert thresholds for rate limiting monitoring
config :fastcheck, :rate_limit_alerts,
  abuse_threshold: String.to_integer(System.get_env("RATE_LIMIT_ABUSE_THRESHOLD") || "10"),
  abuse_window_seconds: 60,
  ets_size_alert_threshold: String.to_integer(System.get_env("ETS_SIZE_ALERT") || "1000")

# Sentry error monitoring configuration
# Only enabled in production when SENTRY_DSN is set
sentry_dsn = System.get_env("SENTRY_DSN")

if sentry_dsn do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: Atom.to_string(config_env()),
    enable_source_code_context: true,
    root_source_code_path: File.cwd!(),
    tags: %{
      env: Atom.to_string(config_env())
    },
    included_environments: [:prod],
    # Filter sensitive data
    filter: FastCheckWeb.SentryFilter,
    # Sample rate for performance monitoring (0.0 to 1.0)
    traces_sample_rate: 0.1
end
