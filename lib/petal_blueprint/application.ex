defmodule PetalBlueprint.Application do
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
        PetalBlueprintWeb.Telemetry,
        PetalBlueprint.Repo,
        FastCheck.TickeraCircuitBreaker,
        {DNSCluster, query: Application.get_env(:petal_blueprint, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: PetalBlueprint.PubSub},
        # Start a worker by calling: PetalBlueprint.Worker.start_link(arg)
        # {PetalBlueprint.Worker, arg},
        # Start to serve requests, typically the last entry
        PetalBlueprintWeb.Endpoint
      ] ++ cache_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PetalBlueprint.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PetalBlueprintWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
