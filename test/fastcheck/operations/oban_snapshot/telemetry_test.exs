defmodule FastCheck.Operations.ObanSnapshot.TelemetryTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.ObanSnapshot.Telemetry

  @base ~U[2026-10-01 10:00:00Z]

  test "metric definitions bind the full event names and emitted measurements" do
    expected = [
      {
        [:fastcheck, :operations, :oban, :jobs],
        [:fastcheck, :operations, :oban, :jobs],
        :value,
        [:queue, :state]
      },
      {
        [:fastcheck, :operations, :oban, :oldest_age_seconds],
        [:fastcheck, :operations, :oban, :oldest_age_seconds],
        :value,
        [:queue, :state]
      },
      {
        [:fastcheck, :operations, :oban, :next_scheduled_in_seconds],
        [:fastcheck, :operations, :oban, :next_scheduled_in_seconds],
        :value,
        [:queue]
      },
      {
        [:fastcheck, :operations, :oban, :discarded_recent],
        [:fastcheck, :operations, :oban, :discarded_recent],
        :value,
        [:queue]
      },
      {
        [:fastcheck, :operations, :oban, :snapshot_age_seconds],
        [:fastcheck, :operations, :oban, :snapshot_age_seconds],
        :value,
        []
      },
      {
        [:fastcheck, :operations, :oban, :snapshot_freshness],
        [:fastcheck, :operations, :oban, :snapshot_freshness],
        :value,
        []
      },
      {
        [:fastcheck, :operations, :oban, :collection_errors_total],
        [:fastcheck, :operations, :oban, :collection_errors_total],
        :count,
        [:reason]
      }
    ]

    metrics = FastCheckWeb.Telemetry.metrics()

    for {name, event_name, measurement, tags} <- expected do
      metric = Enum.find(metrics, &(&1.name == name))
      assert metric, "missing metric #{inspect(name)}"
      assert metric.event_name == event_name
      assert metric.measurement == measurement
      assert metric.tags == tags
    end
  end

  test "full snapshot emits a complete zero-reset matrix" do
    handler = "oban-telemetry-test-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler,
      [
        [:fastcheck, :operations, :oban, :jobs],
        [:fastcheck, :operations, :oban, :oldest_age_seconds],
        [:fastcheck, :operations, :oban, :next_scheduled_in_seconds],
        [:fastcheck, :operations, :oban, :discarded_recent]
      ],
      fn event, measurements, metadata, _config ->
        send(parent, {:metric, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    snapshot = %{
      version: 1,
      collected_at: @base,
      collector_node: "node-a",
      distribution_mode: "shared",
      queues: [
        %{
          queue: "payments",
          available: 0,
          executing: 0,
          retryable: 7,
          scheduled: 2,
          discarded_recent_count: 3,
          oldest_available_age_seconds: 0,
          oldest_executing_age_seconds: 0,
          oldest_retryable_age_seconds: 120,
          next_scheduled_in_seconds: 30,
          configured_limit: 5,
          configured?: true
        }
      ]
    }

    assert :ok = Telemetry.emit_full_snapshot(snapshot)
    _first_messages = collect_metrics(8 * 4 + 8 * 3 + 8 + 8)
    assert :ok = Telemetry.emit_full_snapshot(%{snapshot | queues: []})
    messages = collect_metrics(8 * 4 + 8 * 3 + 8 + 8)

    assert Enum.count(
             messages,
             &match?({:metric, [:fastcheck, :operations, :oban, :jobs], _, _}, &1)
           ) == 32

    assert {:metric, [:fastcheck, :operations, :oban, :jobs], %{value: 0},
            %{queue: "payments", state: "retryable"}} in messages

    assert {:metric, [:fastcheck, :operations, :oban, :oldest_age_seconds], %{value: 0},
            %{queue: "payments", state: "available"}} in messages

    assert {:metric, [:fastcheck, :operations, :oban, :next_scheduled_in_seconds], %{value: 0},
            %{queue: "payments"}} in messages

    assert {:metric, [:fastcheck, :operations, :oban, :discarded_recent], %{value: 0},
            %{queue: "__unexpected__"}} in messages
  end

  defp collect_metrics(expected) do
    Enum.reduce(1..expected, [], fn _, acc ->
      receive do
        {:metric, _event, _measurements, _metadata} = message -> [message | acc]
      after
        500 -> acc
      end
    end)
  end
end
