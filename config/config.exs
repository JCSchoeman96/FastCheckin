# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fastcheck,
  ecto_repos: [FastCheck.Repo],
  ash_domains: [FastCheck.Sales],
  generators: [timestamp_type: :utc_datetime]

# `GET /api/v1/mobile/attendees`: use :repeatable_read so invalidations + attendees + version
# share one DB snapshot. Tests use :none (Ecto Sandbox nested transactions cannot always SET TRANSACTION).
config :fastcheck, :mobile_sync_snapshot_isolation, :repeatable_read

config :fastcheck, Oban,
  repo: FastCheck.Repo,
  queues: [
    scan_persistence: 10,
    sales_inventory: 5,
    payments: 5,
    ticketing: 5,
    sales_maintenance: 3,
    whatsapp_inbound: 5,
    whatsapp_outbound: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/2 * * * *", FastCheck.Workers.CheckoutExpirySweeperWorker}
     ]}
  ]

config :fastcheck, :mobile_scan_ingestion,
  chunk_size: 100,
  live_namespace: "live",
  store: FastCheck.Scans.HotState.RedisStore

config :fastcheck, :event_post_grace_days, 14

config :fastcheck, :sales_checkout_hold_ttl_seconds, 600
config :fastcheck, :sales_checkout_expiry_sweep_batch_size, 200
config :fastcheck, :sales_delivery_token_ttl_seconds, 90 * 24 * 60 * 60

config :fastcheck, :ticket_resend,
  otp_ttl_seconds: 600,
  otp_length: 6,
  max_failed_attempts: 5,
  lock_seconds: 900,
  lookup_limit_per_email_15m: 3,
  lookup_limit_per_source_15m: 5,
  lookup_limit_per_candidate_day: 3

config :fastcheck, :whatsapp_outbound_dedupe_ttl_seconds, 600
config :fastcheck, :whatsapp_ticket_delivery_dedupe_ttl_seconds, 86_400
config :fastcheck, :sales_internal_pilot_enabled, true
config :fastcheck, :paystack_enabled, false
config :fastcheck, :paystack_environment, "test"
config :fastcheck, :paystack_base_url, "https://api.paystack.co"
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
config :fastcheck, :paystack_request_fun, &Req.request/1
config :fastcheck, :paystack_initializing_stale_after_seconds, 120
config :fastcheck, :whatsapp_enabled, false
config :fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.com"
config :fastcheck, :whatsapp_graph_api_version, nil
config :fastcheck, :whatsapp_phone_number_id, nil
config :fastcheck, :whatsapp_business_account_id, nil
config :fastcheck, :whatsapp_access_token, nil
config :fastcheck, :whatsapp_app_secret, nil
config :fastcheck, :whatsapp_verify_token, nil
config :fastcheck, :whatsapp_request_timeout_ms, 5_000
config :fastcheck, :whatsapp_receive_timeout_ms, 10_000
config :fastcheck, :whatsapp_sandbox_mode, true
config :fastcheck, :whatsapp_session_ttl_seconds, 86_400
config :fastcheck, :whatsapp_dedupe_ttl_seconds, 86_400
config :fastcheck, :whatsapp_inbound_queue_enabled, true
config :fastcheck, :whatsapp_inbound_force_enqueue_failure, false
config :fastcheck, :whatsapp_request_fun, &Req.request/1

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

logger_metadata = [
  :request_id,
  :correlation_id,
  :idempotency_key,
  :actor_type,
  :actor_id,
  :order_id,
  :order_public_reference,
  :checkout_session_id,
  :payment_attempt_id,
  :payment_event_id,
  :ticket_issue_id,
  :delivery_attempt_id,
  :conversation_id,
  :provider,
  :provider_reference_redacted,
  :message_type,
  :channel,
  :reason_code,
  :worker,
  :queue,
  :error_code,
  :buyer_phone_last4,
  :buyer_email_domain,
  :ticket_code_redacted,
  :event_id,
  :user_id,
  :ip,
  :device_id,
  :action_required,
  :active_bans,
  :attendee_id,
  :attempt,
  :ban_count,
  :ban_reason,
  :ban_until,
  :blocks,
  :blocks_per_minute,
  :cf_ray,
  :code,
  :content_length,
  :content_type,
  :count,
  :cursor,
  :duplicate,
  :duration_ms,
  :entries,
  :entrance_name,
  :error,
  :event_name,
  :expired_bans,
  :kind,
  :limit,
  :memory_kb,
  :method,
  :missing_ticket_count,
  :next_cursor,
  :old_counters,
  :operator,
  :path,
  :payload,
  :page_limit,
  :payment_status,
  :period,
  :plug,
  :previous_ban_until,
  :query,
  :query_time_ms,
  :raw_size,
  :raw_type,
  :reason,
  :response_time_ms,
  :result,
  :route,
  :scan_count,
  :server,
  :since,
  :source,
  :status,
  :success,
  :sync_type,
  :table,
  :threshold,
  :ticket_code,
  :tickets_info_rows,
  :tickera_sold_tickets,
  :top_violators_count,
  :total,
  :trigger_path,
  :url,
  :user_agent
]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: logger_metadata

# Console logger configuration with metadata
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: logger_metadata

# Cache manager configuration
config :fastcheck, FastCheck.Cache.CacheManager,
  cache_name: :fastcheck_cache,
  default_ttl: :timer.hours(1),
  expiration_interval: :timer.minutes(1),
  max_size: 10_000,
  pubsub_topic: "fastcheck:cache:invalidate"

# Rate limiting configuration
config :fastcheck, FastCheck.RateLimiter, storage: {PlugAttack.Storage.Ets, FastCheck.RateLimiter}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
