defmodule FastCheck.Operations.ObanSnapshot.StoreTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.ObanSnapshot.Store

  @base ~U[2026-10-01 10:00:00Z]

  test "freshness uses exact UTC age boundaries" do
    name = unique_name()
    {:ok, _pid} = start_supervised({Store, name: name})
    snapshot = snapshot(@base)

    assert {:ok, :accepted} = Store.apply_snapshot(snapshot, server: name, now: @base)
    assert %{lifecycle: :current} = Store.state(name)

    assert :current = Store.recompute_freshness(DateTime.add(@base, 30, :second), name)

    assert :stale =
             Store.recompute_freshness(
               @base |> DateTime.add(30, :second) |> DateTime.add(1, :microsecond),
               name
             )

    assert :stale = Store.recompute_freshness(DateTime.add(@base, 60, :second), name)

    assert :unavailable =
             Store.recompute_freshness(
               DateTime.add(@base, 60, :second) |> DateTime.add(1, :microsecond),
               name
             )
  end

  test "startup becomes unavailable after two failed cycles" do
    name = unique_name()
    {:ok, _pid} = start_supervised({Store, name: name})

    assert :uninitialized = Store.lifecycle(name)
    Store.mark_failure(:db_collection_failed, server: name, now: @base)
    assert :uninitialized = Store.lifecycle(name)
    Store.mark_failure(:db_collection_failed, server: name, now: DateTime.add(@base, 1, :second))
    assert :unavailable = Store.lifecycle(name)
  end

  test "an accepted snapshot resets failed cycles and recompute can age it" do
    name = unique_name()
    {:ok, _pid} = start_supervised({Store, name: name})

    Store.mark_failure(:db_collection_failed, server: name, now: @base)
    assert {:ok, :accepted} = Store.apply_snapshot(snapshot(@base), server: name, now: @base)
    assert %{failed_cycles: 0, lifecycle: :current} = Store.state(name)
    assert :stale = Store.recompute_freshness(DateTime.add(@base, 31, :second), name)
  end

  test "rejects shared snapshots that contain job payload fields" do
    name = unique_name()
    {:ok, _pid} = start_supervised({Store, name: name})

    unsafe = Map.put(snapshot(@base), :args, %{"secret" => "nope"})

    assert {:error, :invalid_snapshot_shape} =
             Store.apply_snapshot(unsafe, server: name, now: @base)
  end

  defp snapshot(collected_at) do
    %{
      version: 1,
      collected_at: collected_at,
      collector_node: "test",
      distribution_mode: "shared",
      queues: []
    }
  end

  defp unique_name, do: String.to_atom("oban_store_#{System.unique_integer([:positive])}")
end
