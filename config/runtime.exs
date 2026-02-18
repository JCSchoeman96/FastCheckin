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

  database_host = URI.parse(database_url).host

  if database_host in ["localhost", "127.0.0.1", "::1"] do
    raise """
    DATABASE_URL points to #{database_host}, which is invalid for production deployments.
    Set DATABASE_URL to your managed Postgres host (for Railway, link the Postgres service
    and map its connection string into this service's DATABASE_URL variable).
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

  mobile_app_origin = System.get_env("MOBILE_APP_ORIGIN")
  dashboard_origin = "https://#{domain}"

  cors_origins =
    [mobile_app_origin, dashboard_origin]
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

