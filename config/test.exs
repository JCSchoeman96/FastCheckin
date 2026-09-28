import Config

test_namespace_nonce =
  :crypto.strong_rand_bytes(16)
  |> Base.encode16(case: :lower)

test_namespace_partition =
  case System.get_env("MIX_TEST_PARTITION") do
    partition when is_binary(partition) and partition != "" ->
      ":" <> Regex.replace(~r/[^A-Za-z0-9_.-]/, partition, "_")

    _ ->
      ""
  end

config :fastcheck,
  redis_namespace: "fastcheck:test:#{test_namespace_nonce}#{test_namespace_partition}"

# Local tests are locked to the separate workstation TEST cluster. GitHub Actions
# uses its job-owned ephemeral PostgreSQL service on the fixed service endpoint.
{test_database_host, test_database_port} =
  if System.get_env("GITHUB_ACTIONS") == "true" do
    {"127.0.0.1", 5432}
  else
    {"127.0.0.1", 55_433}
  end

test_db_password =
  case System.get_env("FASTCHECK_TEST_DB_PASSWORD") do
    nil ->
      raise "FASTCHECK_TEST_DB_PASSWORD is required for tests"

    value ->
      value
  end

config :fastcheck, FastCheck.Repo,
  username: "fastcheck_test",
  password: test_db_password,
  hostname: test_database_host,
  port: test_database_port,
  database: "fastcheck_test#{System.get_env("MIX_TEST_PARTITION", "")}",
  show_sensitive_data_on_connection_error: false,
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
  lookup_limit_per_candidate_day: 3,
  otp_email_from_name: "FastCheck Test",
  otp_email_from_email: "no-reply@test.fastcheck.local"

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
