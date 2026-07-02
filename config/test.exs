import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.

# GitHub Actions CI uses DATABASE_URL environment variable
# For local development, use standard PostgreSQL config
config :fastcheck, FastCheck.Repo,
  username: "postgres",
  password: "postgres",
  hostname: if(System.get_env("GITHUB_ACTIONS"), do: "localhost", else: "localhost"),
  # Docker-for-Windows local Postgres is exposed on 5434 (container 5432).
  port:
    if(System.get_env("GITHUB_ACTIONS"),
      do: 5432,
      else: String.to_integer(System.get_env("DB_PORT") || "5434")
    ),
  database: "fastcheck_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fastcheck, FastCheckWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "atwvYDt7V4eZjQzZajHp2VHq5guCXDeT0K8j0kkgAkaH7AEWdPYmcRUntgoGxbdA",
  server: false

# In test we don't send emails
config :fastcheck, FastCheck.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Disable rate limiting in test environment to prevent random test failures
config :fastcheck, :rate_limiting_enabled, false

# See `:mobile_sync_snapshot_isolation` in config.exs — Sandbox savepoints conflict with SET TRANSACTION.
config :fastcheck, :mobile_sync_snapshot_isolation, :none

config :fastcheck, Oban,
  repo: FastCheck.Repo,
  queues: false,
  plugins: false,
  testing: :manual

config :fastcheck, :mobile_scan_ingestion,
  chunk_size: 100,
  live_namespace: "live",
  store: FastCheck.TestSupport.Scans.InMemoryStore

config :fastcheck, :sales_hold_token_pepper, "test-pepper"
config :fastcheck, :ticket_token_pepper, "test-ticket-token-pepper"

config :fastcheck, :ticket_resend,
  hash_pepper: "test-ticket-resend-pepper",
  otp_ttl_seconds: 600,
  otp_length: 6,
  max_failed_attempts: 5,
  lock_seconds: 900,
  lookup_limit_per_email_15m: 3,
  lookup_limit_per_source_15m: 5,
  lookup_limit_per_candidate_day: 3

config :fastcheck, :sales_internal_pilot_enabled, true
config :fastcheck, :paystack_enabled, true
config :fastcheck, :paystack_environment, "test"
config :fastcheck, :paystack_base_url, "https://api.paystack.co"
config :fastcheck, :paystack_public_key, "pk_test_fake_key"
config :fastcheck, :paystack_secret_key, "sk_test_fake_key"
config :fastcheck, :paystack_timeout_ms, 10_000

config :fastcheck, :paystack_allowed_channels, [
  "card",
  "bank",
  "bank_transfer",
  "eft",
  "capitec_pay"
]

config :fastcheck,
       :paystack_callback_url,
       "https://scan.voelgoed.co.za/sales/payments/paystack/callback"

config :fastcheck, :paystack_webhook_url, "https://scan.voelgoed.co.za/api/sales/paystack/webhook"
