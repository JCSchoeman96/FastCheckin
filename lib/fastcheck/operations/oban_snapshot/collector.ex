defmodule FastCheck.Operations.ObanSnapshot.Collector do
  @moduledoc """
  Periodic lease, collection, follower sync, and freshness coordinator.
  """

  use GenServer

  alias FastCheck.Operations.ObanSnapshot
  alias FastCheck.Operations.ObanSnapshot.Clock
  alias FastCheck.Operations.ObanSnapshot.Query
  alias FastCheck.Operations.ObanSnapshot.RedisMirror
  alias FastCheck.Operations.ObanSnapshot.Store
  alias FastCheck.Operations.ObanSnapshot.Telemetry
  alias FastCheck.Repo

  @interval_ms 15_000
  @future_skew_seconds 5
  @advisory_lock_key 9_276_451

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{opts: opts, interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)}

    if Keyword.get(opts, :schedule?, true) do
      {:ok, schedule_next(state)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    tick_once(state.opts)
    {:noreply, schedule_next(state)}
  end

  @spec collect_db(module(), DateTime.t(), String.t()) ::
          {:ok, map()} | :skipped | {:error, atom()}
  def collect_db(
        repo \\ Repo,
        collected_at \\ Clock.utc_now(),
        collector_node \\ Atom.to_string(node())
      ) do
    transaction = fn ->
      case repo.query("SELECT pg_try_advisory_xact_lock($1::bigint)", [@advisory_lock_key]) do
        {:ok, %{rows: [[true]]}} ->
          with {:ok, active} <- Query.active_rows(repo, collected_at),
               {:ok, discarded} <- Query.discarded_rows(repo, collected_at) do
            {:ok,
             Query.build_snapshot(active, discarded, collected_at, collector_node: collector_node)}
          else
            _ -> {:error, :db_collection_failed}
          end

        {:ok, %{rows: [[false]]}} ->
          :skipped

        _ ->
          {:error, :db_collection_failed}
      end
    end

    case repo.transaction(transaction) do
      {:ok, {:ok, snapshot}} -> {:ok, snapshot}
      {:ok, :skipped} -> :skipped
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _reason} -> {:error, :db_collection_failed}
    end
  rescue
    _exception -> {:error, :db_collection_failed}
  end

  @spec tick_once(keyword()) :: :ok
  def tick_once(opts \\ []) do
    now = Keyword.get(opts, :now, Clock.utc_now())
    node_id = Keyword.get(opts, :node_id, Atom.to_string(node()))
    repo = Keyword.get(opts, :repo, Repo)
    store_server = Keyword.get(opts, :store_server, Store)
    command_fun = Keyword.get(opts, :command_fun)

    apply_fun =
      Keyword.get(opts, :apply_fun, fn snapshot ->
        Store.apply_snapshot(snapshot, server: store_server, now: now)
      end)

    recompute_fun =
      Keyword.get(opts, :recompute_fun, fn current_now ->
        Store.recompute_freshness(current_now, store_server)
      end)

    state_fun = Keyword.get(opts, :state_fun, fn -> Store.state(store_server) end)
    freshness_fun = Keyword.get(opts, :freshness_fun, &Telemetry.emit_freshness/2)
    error_fun = Keyword.get(opts, :error_fun, &Telemetry.emit_error/1)

    failure_fun =
      Keyword.get(opts, :failure_fun, fn reason ->
        Store.mark_failure(reason, server: store_server, now: now)
      end)

    write_fun =
      Keyword.get(opts, :write_fun, fn snapshot ->
        RedisMirror.write_snapshot(snapshot, command_opts(command_fun))
      end)

    read_fun =
      Keyword.get(opts, :read_fun, fn -> RedisMirror.read_snapshot(command_opts(command_fun)) end)

    lease_fun =
      Keyword.get(opts, :lease_fun, fn ->
        RedisMirror.acquire_lease(node_id, command_opts(command_fun))
      end)

    collect_fun = Keyword.get(opts, :collect_fun, fn -> collect_db(repo, now, node_id) end)

    try do
      case lease_fun.() do
        {:ok, true} ->
          handle_lease_winner(collect_fun, apply_fun, write_fun, error_fun, failure_fun, opts)

        {:ok, false} ->
          handle_follower(read_fun, apply_fun, state_fun, error_fun, failure_fun, now, opts)

        {:error, _reason} ->
          error_fun.(:lease_unavailable)
          set_distribution_mode(opts, "coordination_degraded")
          handle_degraded_collection(collect_fun, apply_fun, error_fun, failure_fun, opts)
      end
    rescue
      _exception ->
        error_fun.(:db_collection_failed)
        failure_fun.(:db_collection_failed)
    after
      recompute_fun.(now)
      freshness_fun.(state_fun.(), now)
    end

    :ok
  end

  @spec validate_shared_snapshot(map(), DateTime.t(), map() | nil) ::
          {:ok, map()} | {:ignore, :older_or_equal} | {:error, atom()}
  def validate_shared_snapshot(snapshot, now, current_snapshot \\ nil) do
    with {:ok, normalized} <- ObanSnapshot.normalize(snapshot),
         true <-
           DateTime.compare(
             normalized.collected_at,
             DateTime.add(now, @future_skew_seconds, :second)
           ) != :gt,
         true <- newer_than_local?(normalized, current_snapshot) do
      {:ok, normalized}
    else
      false ->
        case ObanSnapshot.normalize(snapshot) do
          {:ok, normalized} when not is_nil(current_snapshot) ->
            if DateTime.compare(normalized.collected_at, current_snapshot.collected_at) != :gt,
              do: {:ignore, :older_or_equal},
              else: {:error, :invalid_shared_snapshot}

          _ ->
            {:error, :invalid_shared_snapshot}
        end

      {:error, _reason} ->
        {:error, :invalid_shared_snapshot}
    end
  end

  defp handle_lease_winner(collect_fun, apply_fun, write_fun, error_fun, failure_fun, opts) do
    case collect_fun.() do
      {:ok, snapshot} ->
        case apply_fun.(snapshot) do
          {:ok, :accepted} ->
            emit_full_snapshot(opts, snapshot)

            case write_fun.(snapshot) do
              :ok ->
                :ok

              {:error, _reason} ->
                error_fun.(:snapshot_write_failed)
                set_distribution_mode(opts, "shared_mirror_degraded")
            end

          _ ->
            failure_fun.(:db_collection_failed)
            error_fun.(:db_collection_failed)
        end

      :skipped ->
        :ok

      {:error, _reason} ->
        failure_fun.(:db_collection_failed)
        error_fun.(:db_collection_failed)
    end
  end

  defp handle_degraded_collection(collect_fun, apply_fun, error_fun, failure_fun, opts) do
    case collect_fun.() do
      {:ok, snapshot} ->
        case apply_fun.(snapshot) do
          {:ok, :accepted} ->
            emit_full_snapshot(opts, snapshot)

          _ ->
            failure_fun.(:db_collection_failed)
            error_fun.(:db_collection_failed)
        end

      :skipped ->
        :ok

      {:error, _reason} ->
        failure_fun.(:db_collection_failed)
        error_fun.(:db_collection_failed)
    end
  end

  defp handle_follower(read_fun, apply_fun, state_fun, error_fun, failure_fun, now, opts) do
    case read_fun.() do
      {:ok, nil} ->
        :ok

      {:ok, snapshot} ->
        case validate_shared_snapshot(snapshot, now, current_snapshot(opts, state_fun)) do
          {:ok, normalized} ->
            case apply_fun.(normalized) do
              {:ok, :accepted} -> emit_full_snapshot(opts, normalized)
              _ -> :ok
            end

          {:ignore, _reason} ->
            :ok

          {:error, _reason} ->
            error_fun.(:invalid_shared_snapshot)
        end

      {:error, _reason} ->
        error_fun.(:snapshot_read_failed)
        failure_fun.(:snapshot_read_failed)
    end
  end

  defp current_snapshot(opts, state_fun) do
    case Keyword.get(opts, :snapshot_fun) do
      nil ->
        case state_fun.() do
          %{snapshot: snapshot} -> snapshot
          _ -> Store.snapshot(Keyword.get(opts, :store_server, Store))
        end

      fun ->
        fun.()
    end
  end

  defp emit_full_snapshot(opts, snapshot) do
    case Keyword.get(opts, :telemetry_fun) do
      nil -> Telemetry.emit_full_snapshot(snapshot)
      fun -> fun.(snapshot)
    end
  end

  defp set_distribution_mode(opts, mode) do
    case Keyword.get(opts, :distribution_fun) do
      nil -> Store.set_distribution_mode(mode, server: Keyword.get(opts, :store_server, Store))
      fun -> fun.(mode)
    end
  rescue
    _exception -> :ok
  end

  defp command_opts(nil), do: []
  defp command_opts(fun), do: [command_fun: fun]

  defp newer_than_local?(_incoming, nil), do: true

  defp newer_than_local?(%{collected_at: incoming}, %{collected_at: current}),
    do: DateTime.compare(incoming, current) == :gt

  defp schedule_next(state) do
    jitter = :rand.uniform(2_001) - 1
    Process.send_after(self(), :tick, state.interval_ms + jitter)
    state
  end
end
