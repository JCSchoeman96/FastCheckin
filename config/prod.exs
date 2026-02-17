import Config

# For production, only set compile-time configuration here.
# All runtime env-var reads (DATABASE_URL, SECRET_KEY_BASE, PORT, etc.)
# live in config/runtime.exs so releases can be built without secrets.

# Cache-busting: Phoenix reads the digest manifest at boot to serve
# fingerprinted asset URLs.
config :fastcheck, FastCheckWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Use the Req-based Swoosh API client and disable the local mailbox cache for
# production deliveries.
config :swoosh, api_client: Swoosh.ApiClient.Req
config :swoosh, local: false

# Only emit :info logs in production to reduce noise.
config :logger, level: :info
