defmodule FastCheck.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    cache_children =
      if Application.get_env(:fastcheck, :cache_enabled, true) do
        [FastCheck.Cache.CacheManager]
      else
        []
      end

    children =
      [
        FastCheckWeb.Telemetry,
        FastCheck.Repo,
        FastCheck.TickeraCircuitBreaker,
        {DNSCluster, query: Application.get_env(:fastcheck, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: FastCheck.PubSub},
        # Start a worker by calling: FastCheck.Worker.start_link(arg)
        # {FastCheck.Worker, arg},
        # Start to serve requests, typically the last entry
        FastCheckWeb.Endpoint
      ] ++ cache_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FastCheck.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FastCheckWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
