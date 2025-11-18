# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fastcheck,
  ecto_repos: [FastCheck.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :fastcheck, FastCheckWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FastCheckWeb.ErrorHTML, json: FastCheckWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FastCheck.PubSub,
  live_view: [signing_salt: "VA/1SpaB"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :fastcheck, FastCheck.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  fastcheck: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.17",
  fastcheck: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Cache manager configuration
config :fastcheck, FastCheck.Cache.CacheManager,
  cache_name: :fastcheck_cache,
  default_ttl: :timer.hours(1),
  expiration_interval: :timer.minutes(1),
  max_size: 10_000,
  pubsub_topic: "fastcheck:cache:invalidate"

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
