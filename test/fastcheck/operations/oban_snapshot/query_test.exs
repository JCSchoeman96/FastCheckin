defmodule FastCheck.Operations.ObanSnapshot.QueryTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.ObanSnapshot.Query

  @base ~U[2026-10-01 10:00:00Z]

  test "builds every bounded queue row and computes state-specific timing" do
    active = [
      %{
        queue: "payments",
        state: "retryable",
        count: 7,
        min_scheduled_at: nil,
        min_attempted_at: ~U[2026-10-01 09:58:00Z]
      },
      %{
        queue: "payments",
        state: "scheduled",
        count: 2,
        min_scheduled_at: ~U[2026-10-01 10:00:30Z],
        min_attempted_at: nil
      },
      %{
        queue: "__unexpected__",
        state: "retryable",
        count: 4,
        min_scheduled_at: nil,
        min_attempted_at: ~U[2026-10-01 09:59:00Z]
      }
    ]

    discarded = [%{queue: "payments", count: 3}, %{queue: "unknown", count: 9}]

    snapshot = Query.build_snapshot(active, discarded, @base, collector_node: "node-a")
    payments = Enum.find(snapshot.queues, &(&1.queue == "payments"))
    unexpected = Enum.find(snapshot.queues, &(&1.queue == "__unexpected__"))

    assert snapshot.version == 1
    assert snapshot.collected_at == @base
    assert payments.retryable == 7
    assert payments.oldest_retryable_age_seconds == 120.0
    assert payments.scheduled == 2
    assert payments.next_scheduled_in_seconds == 30.0
    assert payments.discarded_recent_count == 3
    assert unexpected.retryable == 4
    assert unexpected.discarded_recent_count == 9
    assert length(snapshot.queues) == 8
  end

  test "active query normalizes arbitrary queues and bounds grouping" do
    assert {:ok, []} = Query.active_rows(__MODULE__.QueryTestRepo, @base)
    assert_receive {:query, sql, _params}

    assert sql =~ "CASE WHEN queue = ANY"
    assert sql =~ "GROUP BY normalized_queue, state"
    refute sql =~ "args"
    refute sql =~ "errors"
    refute sql =~ "meta"
  end

  defmodule QueryTestRepo do
    def query(sql, params) do
      send(self(), {:query, sql, params})
      {:ok, %{rows: []}}
    end
  end
end
