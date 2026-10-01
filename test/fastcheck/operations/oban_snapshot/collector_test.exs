defmodule FastCheck.Operations.ObanSnapshot.CollectorTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.ObanSnapshot.Collector

  @base ~U[2026-10-01 10:00:00Z]

  test "database collection uses a transaction advisory xact lock before aggregates" do
    Process.put(:collector_test_parent, self())
    assert {:ok, snapshot} = Collector.collect_db(__MODULE__.Repo, @base, "node-a")
    assert snapshot.version == 1
    assert_receive :transaction_started
    assert_receive {:query, lock_sql}
    assert lock_sql =~ "pg_try_advisory_xact_lock"
    refute lock_sql =~ "pg_advisory_lock"
    assert_receive {:query, active_sql}
    assert active_sql =~ "CASE WHEN queue = ANY"
    assert_receive {:query, discarded_sql}
    assert discarded_sql =~ "CASE WHEN queue = ANY"
  end

  defmodule Repo do
    def transaction(fun) do
      send(Process.get(:collector_test_parent), :transaction_started)
      {:ok, fun.()}
    end

    def query(sql, _params) do
      send(Process.get(:collector_test_parent), {:query, sql})

      cond do
        String.contains?(sql, "pg_try_advisory_xact_lock") -> {:ok, %{rows: [[true]]}}
        String.contains?(sql, "ANY($2") -> {:ok, %{rows: []}}
        String.contains?(sql, "discarded") -> {:ok, %{rows: []}}
      end
    end
  end

  test "a transaction lock miss skips both aggregate queries" do
    Process.put(:collector_test_parent, self())
    assert :skipped = Collector.collect_db(__MODULE__.NoLockRepo, @base, "node-a")
    assert_receive {:query, sql}
    assert sql =~ "pg_try_advisory_xact_lock"
    refute_receive {:aggregate_query, _}
  end

  defmodule NoLockRepo do
    def transaction(fun), do: {:ok, fun.()}

    def query(sql, _params) do
      if String.contains?(sql, "pg_try_advisory_xact_lock") do
        send(Process.get(:collector_test_parent), {:query, sql})
        {:ok, %{rows: [[false]]}}
      else
        send(Process.get(:collector_test_parent), {:aggregate_query, sql})
        raise "aggregate query ran without the xact lock"
      end
    end
  end

  test "a failed Redis lease falls back to one transaction-fenced collection" do
    test_pid = self()

    assert :ok =
             Collector.tick_once(
               now: @base,
               node_id: "node-a",
               lease_fun: fn -> {:error, :redis_unavailable} end,
               collect_fun: fn ->
                 send(test_pid, :collected)

                 {:ok,
                  %{
                    version: 1,
                    collected_at: @base,
                    collector_node: "node-a",
                    distribution_mode: "shared",
                    queues: []
                  }}
               end,
               apply_fun: fn _snapshot -> {:ok, :accepted} end,
               write_fun: fn _snapshot -> flunk("degraded collection must not write Redis") end,
               recompute_fun: fn _now -> :unavailable end,
               freshness_fun: fn _state, _now -> :ok end,
               state_fun: fn -> %{} end
             )

    assert_received :collected
  end

  test "a healthy non-holder reads Redis once and does not query Postgres" do
    parent = self()

    snapshot = %{
      version: 1,
      collected_at: DateTime.add(@base, -1, :second),
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: []
    }

    assert :ok =
             Collector.tick_once(
               now: @base,
               lease_fun: fn -> {:ok, false} end,
               read_fun: fn ->
                 send(parent, :redis_get)
                 {:ok, snapshot}
               end,
               collect_fun: fn -> flunk("followers must not collect from Postgres") end,
               apply_fun: fn _ ->
                 send(parent, :accepted)
                 {:ok, :accepted}
               end,
               snapshot_fun: fn -> nil end,
               recompute_fun: fn _ -> :current end,
               freshness_fun: fn _state, _now -> :ok end,
               state_fun: fn -> %{} end
             )

    assert_received :redis_get
    assert_received :accepted
  end

  test "a mirror write failure leaves local acceptance and marks degraded distribution" do
    parent = self()

    snapshot = %{
      version: 1,
      collected_at: @base,
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: []
    }

    assert :ok =
             Collector.tick_once(
               now: @base,
               lease_fun: fn -> {:ok, true} end,
               collect_fun: fn -> {:ok, snapshot} end,
               apply_fun: fn _ ->
                 send(parent, :accepted)
                 {:ok, :accepted}
               end,
               write_fun: fn _ -> {:error, :redis_unavailable} end,
               distribution_fun: fn mode -> send(parent, {:distribution, mode}) end,
               recompute_fun: fn _ -> :current end,
               freshness_fun: fn _state, _now -> :ok end,
               state_fun: fn -> %{} end
             )

    assert_received :accepted
    assert_received {:distribution, "shared_mirror_degraded"}
  end

  test "future shared snapshots are rejected using UTC wall-clock skew" do
    snapshot = %{
      version: 1,
      collected_at: DateTime.add(@base, 6, :second),
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: []
    }

    assert {:error, :invalid_shared_snapshot} =
             Collector.validate_shared_snapshot(snapshot, @base)

    assert {:error, :invalid_shared_snapshot} =
             Collector.validate_shared_snapshot(
               snapshot,
               @base,
               %{collected_at: DateTime.add(@base, 10, :second)}
             )
  end

  test "equal and older shared snapshots are ignored" do
    snapshot = %{
      version: 1,
      collected_at: @base,
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: []
    }

    assert {:ignore, :older_or_equal} =
             Collector.validate_shared_snapshot(snapshot, @base, %{collected_at: @base})

    assert {:ignore, :older_or_equal} =
             Collector.validate_shared_snapshot(
               %{snapshot | collected_at: DateTime.add(@base, -1, :second)},
               @base,
               %{collected_at: @base}
             )
  end
end
