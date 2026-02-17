defmodule FastCheck.AbuseTrackingTable do
  @moduledoc false

  use GenServer
  require Logger

  @table :fastcheck_abuse_tracking

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    ensure_table!()
    {:ok, Map.put(state, :table, @table)}
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        _tid =
          :ets.new(@table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])

        Logger.info("ETS abuse tracking table created: #{@table}")
        :ok

      _tid ->
        Logger.info("ETS abuse tracking table already exists: #{@table}")
        :ok
    end
  rescue
    e in ArgumentError ->
      Logger.warning("ETS abuse tracking table ensure hit race: #{Exception.message(e)}")

      :ok
  end
end
