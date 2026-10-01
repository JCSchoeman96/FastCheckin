defmodule FastCheck.Operations.ObanSnapshot.Store do
  @moduledoc """
  GenServer-owned ETS projection for global Oban snapshots.
  """

  use GenServer

  alias FastCheck.Operations.ObanSnapshot
  alias FastCheck.Operations.ObanSnapshot.Clock

  @topic "operations:oban_snapshot"
  @current_max_age_seconds 30
  @stale_max_age_seconds 60
  @startup_failure_threshold 2
  @startup_unavailable_after_seconds 45

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    server = Keyword.get(opts, :name, __MODULE__)
    table = Keyword.get(opts, :table, table_name(server))
    table = :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])
    now = Keyword.get(opts, :now, Clock.utc_now())

    state = %{
      table: table,
      lifecycle: :uninitialized,
      snapshot: nil,
      accepted_collected_at: nil,
      initialized_at: now,
      failed_cycles: 0,
      snapshot_age_seconds: 0,
      distribution_mode: "unavailable",
      last_error: nil
    }

    {:ok, put_projection(state)}
  end

  @spec snapshot(GenServer.server()) :: map() | nil
  def snapshot(server \\ __MODULE__), do: read_projection(server, :snapshot)

  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: read_projection(server, :state) || %{}

  @spec lifecycle(GenServer.server()) :: atom()
  def lifecycle(server \\ __MODULE__), do: Map.get(state(server), :lifecycle, :uninitialized)

  @spec apply_snapshot(map(), keyword()) :: {:ok, :accepted | :ignored} | {:error, atom()}
  def apply_snapshot(snapshot, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now = Keyword.get(opts, :now, Clock.utc_now())
    GenServer.call(server, {:apply_snapshot, snapshot, now})
  end

  @spec recompute_freshness(DateTime.t(), GenServer.server()) :: atom()
  def recompute_freshness(now, server \\ __MODULE__) do
    GenServer.call(server, {:recompute_freshness, now})
  end

  @spec mark_failure(atom(), keyword()) :: atom()
  def mark_failure(reason, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    now = Keyword.get(opts, :now, Clock.utc_now())
    GenServer.call(server, {:mark_failure, reason, now})
  end

  @spec set_distribution_mode(String.t(), keyword()) :: :ok
  def set_distribution_mode(mode, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:set_distribution_mode, mode})
  end

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(FastCheck.PubSub, @topic)

  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def handle_call({:apply_snapshot, incoming, now}, _from, state) do
    case ObanSnapshot.normalize(incoming) do
      {:ok, snapshot} ->
        if newer?(snapshot, state.snapshot) do
          lifecycle = lifecycle_for(snapshot.collected_at, now)

          state =
            state
            |> Map.merge(%{
              snapshot: snapshot,
              accepted_collected_at: snapshot.collected_at,
              lifecycle: lifecycle,
              failed_cycles: 0,
              snapshot_age_seconds: age_seconds(snapshot.collected_at, now),
              distribution_mode: snapshot.distribution_mode,
              last_error: nil
            })
            |> put_projection()

          broadcast({:snapshot, snapshot})
          {:reply, {:ok, :accepted}, state}
        else
          {:reply, {:ok, :ignored}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: reason} |> put_projection()}
    end
  end

  @impl true
  def handle_call({:recompute_freshness, now}, _from, state) do
    previous_lifecycle = state.lifecycle

    lifecycle =
      case state.accepted_collected_at do
        %DateTime{} = collected_at -> lifecycle_for(collected_at, now)
        nil -> startup_lifecycle(state, now)
      end

    state = %{state | lifecycle: lifecycle, snapshot_age_seconds: snapshot_age(state, now)}
    changed? = lifecycle != previous_lifecycle
    state = put_projection(state)

    if changed?, do: broadcast({:lifecycle, lifecycle})
    {:reply, lifecycle, state}
  end

  @impl true
  def handle_call({:mark_failure, reason, now}, _from, state) do
    previous_lifecycle = state.lifecycle
    state = %{state | failed_cycles: state.failed_cycles + 1, last_error: reason}
    lifecycle = startup_lifecycle(state, now)
    state = %{state | lifecycle: lifecycle, snapshot_age_seconds: snapshot_age(state, now)}
    state = put_projection(state)
    if lifecycle != previous_lifecycle, do: broadcast({:lifecycle, lifecycle})
    {:reply, lifecycle, state}
  end

  @impl true
  def handle_call({:set_distribution_mode, mode}, _from, state) do
    snapshot =
      case state.snapshot do
        nil -> nil
        snapshot -> %{snapshot | distribution_mode: mode}
      end

    {:reply, :ok, %{state | snapshot: snapshot, distribution_mode: mode} |> put_projection()}
  end

  defp newer?(%{collected_at: _incoming}, nil), do: true

  defp newer?(%{collected_at: incoming}, %{collected_at: current}),
    do: DateTime.compare(incoming, current) == :gt

  defp lifecycle_for(collected_at, now) do
    age = age_seconds(collected_at, now)

    cond do
      age <= @current_max_age_seconds -> :current
      age <= @stale_max_age_seconds -> :stale
      true -> :unavailable
    end
  end

  defp startup_lifecycle(state, now) do
    elapsed = age_seconds(state.initialized_at, now)

    if state.failed_cycles >= @startup_failure_threshold or
         elapsed >= @startup_unavailable_after_seconds do
      :unavailable
    else
      :uninitialized
    end
  end

  defp snapshot_age(%{accepted_collected_at: nil}, _now), do: 0

  defp snapshot_age(%{accepted_collected_at: collected_at}, now),
    do: age_seconds(collected_at, now)

  defp age_seconds(earlier, later) do
    max(DateTime.diff(later, earlier, :microsecond) / 1_000_000, 0)
  end

  defp read_projection(server, key) do
    table = table_name(server)

    case :ets.whereis(table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> value
          [] -> nil
        end
    end
  end

  defp put_projection(state) do
    :ets.insert(state.table, {:snapshot, state.snapshot})
    :ets.insert(state.table, {:state, public_state(state)})
    state
  end

  defp public_state(state) do
    Map.take(state, [
      :lifecycle,
      :accepted_collected_at,
      :failed_cycles,
      :snapshot_age_seconds,
      :distribution_mode,
      :last_error
    ])
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(FastCheck.PubSub, @topic, {:oban_snapshot, message})
  catch
    :exit, _ -> :ok
  end

  defp table_name(__MODULE__), do: :fastcheck_operations_oban_snapshot
  defp table_name(server) when is_atom(server), do: server
  defp table_name(_server), do: :fastcheck_operations_oban_snapshot
end
