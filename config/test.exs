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
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
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
