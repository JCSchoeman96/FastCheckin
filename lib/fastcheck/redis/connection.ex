defmodule FastCheck.Redis.Connection do
  @moduledoc """
  Supervised Redis connection used by the scan ingestion path and scaffolded
  Redis-backed helpers.
  """

  use Supervisor

  @redix_name FastCheck.Redix

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    redis_url = Application.get_env(:fastcheck, :redis_url, "redis://localhost:6379")

    children = [
      %{
        id: @redix_name,
        start: {Redix, :start_link, [redis_url, [name: @redix_name]]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
