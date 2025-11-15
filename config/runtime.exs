import Config

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

# Allow operators to run `PHX_SERVER=true bin/petal_blueprint start` so releases
# boot the HTTP endpoint automatically.
if System.get_env("PHX_SERVER") do
  config :petal_blueprint, PetalBlueprintWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Route all production database traffic through pgBouncer so the scanners can
  # share a compact pool of upstream PostgreSQL connections.
  database_url =
    System.get_env("DATABASE_URL") ||
      "ecto://postgres:password@pgbouncer:6432/fastcheck_prod"

  config :petal_blueprint, PetalBlueprint.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "50"),
    queue_target: 5_000,
    queue_interval: 1_000

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
  config :petal_blueprint, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Configure the endpoint with runtime values so releases can adjust ports and
  # hosts without being recompiled.
  config :petal_blueprint, PetalBlueprintWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    url: [host: domain, scheme: "https", port: 443],
    check_origin: ["https://#{domain}"],
    secret_key_base: secret_key_base
end
