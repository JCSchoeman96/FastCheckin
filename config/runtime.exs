import Config

encryption_key =
  System.get_env("ENCRYPTION_KEY") ||
    if config_env() == :prod do
      raise """
      environment variable ENCRYPTION_KEY is missing.
      Generate a strong 32+ byte key and export it before booting FastCheck.
      """
    else
      "dev fastcheck encryption key dev fastcheck encryption key"
    end

config :fastcheck, :encryption_key, encryption_key

mobile_token_secret =
  System.get_env("MOBILE_JWT_SECRET") ||
    if config_env() == :prod do
      raise """
      environment variable MOBILE_JWT_SECRET is missing.
      Generate a strong shared secret and export it before booting FastCheck.
      """
    else
      "dev fastcheck mobile jwt secret key"
    end

config :fastcheck, FastCheck.Mobile.Token,
  secret_key: mobile_token_secret,
  token_ttl_seconds: String.to_integer(System.get_env("MOBILE_JWT_TTL_SECONDS") || "86400"),
  issuer: System.get_env("MOBILE_JWT_ISSUER") || "fastcheck",
  algorithm: System.get_env("MOBILE_JWT_ALGORITHM") || "HS256"

# Cache defaults shared across all environments. The values can be overridden
# via environment variables without recompiling the release.
cache_enabled = System.get_env("CACHE_ENABLED", "true") == "true"

cache_ttl = [
  ticket_config: :timer.hours(1),
  event_metadata: :timer.hours(6),
  occupancy: :timer.seconds(10)
]

redis_url = System.get_env("REDIS_URL", "redis://localhost:6379")

config :fastcheck,
  cache_enabled: cache_enabled,
  cache_ttl: cache_ttl,
  redis_url: redis_url

# config/runtime.exs is executed for all environments and is the right place to
# read secrets that should not be baked into the release.

# Allow operators to run `PHX_SERVER=true bin/fastcheck start` so releases
# boot the HTTP endpoint automatically.
if System.get_env("PHX_SERVER") do
  config :fastcheck, FastCheckWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Route all production database traffic through pgBouncer so the scanners can
  # share a compact pool of upstream PostgreSQL connections.
  database_url =
    System.get_env("DATABASE_URL") ||
      "ecto://postgres:password@pgbouncer:6432/fastcheck_prod"

  config :fastcheck, FastCheck.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "20"),
    queue_target: 5_000,
    queue_interval: 1_000,
    # Log queries that exceed the threshold (in microseconds, default 100ms)
    log: false,
    telemetry_prefix: [:fastcheck, :repo]

  # The secret key base signs/encrypts cookies and tokens. Generate it with
  # `mix phx.gen.secret` and keep it outside of version control.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  # DOMAIN and PORT mirror the entries in .env.example so systemd (or any
  # process manager) can wire Phoenix up behind a reverse proxy.
  domain = System.get_env("DOMAIN") || System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "8080")

  # DNS cluster query makes it possible to auto-discover other nodes when the
  # app runs on Kubernetes or Fly.io. Leave it nil when not clustering.
  config :fastcheck, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Configure the endpoint with runtime values so releases can adjust ports and
  # hosts without being recompiled.
  config :fastcheck, FastCheckWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    url: [host: domain, scheme: "https", port: 443],
    check_origin: ["https://#{domain}"],
    secret_key_base: secret_key_base
end

# Runtime configurable rate limiting
# Override defaults via environment variables for production tuning without recompilation
config :fastcheck, FastCheck.RateLimiter,
  sync_limit: String.to_integer(System.get_env("RATE_LIMIT_SYNC") || "3"),
  sync_period: 300_000,
  occupancy_limit: String.to_integer(System.get_env("RATE_LIMIT_OCCUPANCY") || "10"),
  occupancy_period: 60_000,
  checkin_limit: String.to_integer(System.get_env("RATE_LIMIT_CHECKIN") || "30"),
  checkin_period: 60_000,
  scan_limit: String.to_integer(System.get_env("RATE_LIMIT_SCAN") || "50"),
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
