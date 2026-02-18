defmodule FastCheck.Cache.EtsOwner do
  @moduledoc false
  use GenServer

  alias FastCheck.Cache.EtsLayer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ok = EtsLayer.init()
    {:ok, %{}}
  end
end
