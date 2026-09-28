import Config

perf_db_password =
  case System.get_env("FASTCHECK_PERF_DB_PASSWORD") do
    password when is_binary(password) ->
      password = String.trim(password)

      if password == "" do
        raise "FASTCHECK_PERF_DB_PASSWORD must not be blank"
      end

      password

    _ ->
      raise "FASTCHECK_PERF_DB_PASSWORD is required for MIX_ENV=perf"
  end

migration_database_url =
  case System.get_env("MIGRATION_DATABASE_URL") do
    nil -> nil
    value -> String.trim(value)
  end

repo_connection_opts =
  case migration_database_url do
    nil ->
      [
        username: "fastcheck_perf",
        password: perf_db_password,
        hostname: "127.0.0.1",
        port: 5434,
        database: "fastcheck_prod"
      ]

    "" ->
      [
        username: "fastcheck_perf",
        password: perf_db_password,
        hostname: "127.0.0.1",
        port: 5434,
        database: "fastcheck_prod"
      ]

    url ->
      [url: url]
  end

config :fastcheck,
       FastCheck.Repo,
       repo_connection_opts
       |> Keyword.merge(
         prepare: :named,
         stacktrace: true,
         show_sensitive_data_on_connection_error: false,
         pool_size: String.to_integer(System.get_env("POOL_SIZE", "20")),
         queue_target: 50,
         queue_interval: 1_000,
         preallocate: true,
         timeout: 30_000,
         log: :info
       )

config :fastcheck, :database_pooling, mode: :direct, prepare: :named
config :fastcheck, :oban_runtime, notifier: :postgres
config :fastcheck, Oban, notifier: {Oban.Notifiers.Postgres, []}

config :fastcheck, FastCheckWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  server: true,
  check_origin: false,
  secret_key_base: System.get_env("SECRET_KEY_BASE")

config :fastcheck, :enable_metrics, true
