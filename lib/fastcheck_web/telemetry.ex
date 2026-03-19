defmodule FastCheckWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      counter("phoenix.endpoint.stop.count",
        tags: [:method, :status],
        description: "Total HTTP requests by method and status code"
      ),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        tags: [:route, :method, :status],
        reporter_options: [buckets: request_duration_buckets()],
        description: "HTTP request latency distribution"
      ),
      counter("fastcheck.phoenix.route_dispatch.count",
        tags: [:route, :plug],
        description: "Route dispatch count by route and plug"
      ),
      counter("fastcheck.phoenix.exception.count",
        tags: [:kind, :route],
        description: "Request exceptions by type and route"
      ),
      counter("phoenix.socket_drain.count"),
      distribution("phoenix.channel_handled_in.duration",
        unit: {:native, :millisecond},
        tags: [:event],
        reporter_options: [buckets: request_duration_buckets()],
        description: "Phoenix channel handled_in duration"
      ),

      # Database Metrics
      counter("fastcheck.repo.query.count",
        tags: [:source],
        description: "Total database queries by source"
      ),
      distribution("fastcheck.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: database_duration_buckets()],
        description: "Total database query time"
      ),
      distribution("fastcheck.repo.query.decode_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: database_duration_buckets()],
        description: "Database decode time"
      ),
      distribution("fastcheck.repo.query.query_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: database_duration_buckets()],
        description: "Database execution time"
      ),
      distribution("fastcheck.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: database_duration_buckets()],
        description: "Database queue wait time"
      ),
      distribution("fastcheck.repo.query.idle_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: database_duration_buckets()],
        description: "Database idle time before checkout"
      ),
      counter("fastcheck.repo.slow_query_warning.count",
        description: "Total slow query warnings"
      ),
      counter("fastcheck.repo.slow_query_critical.count",
        description: "Total critical slow queries"
      ),

      # Scanner and mobile sync performance metrics
      distribution("fastcheck.scanner.scan.duration.duration_ms",
        unit: {:millisecond, :millisecond},
        tags: [:operation, :status],
        reporter_options: [buckets: scan_duration_buckets()],
        description: "Scanner hot-path duration in milliseconds"
      ),
      distribution("fastcheck.mobile_sync.batch.duration.duration_ms",
        unit: {:millisecond, :millisecond},
        tags: [:event_id],
        reporter_options: [buckets: batch_duration_buckets()],
        description: "Mobile sync batch processing duration in milliseconds"
      ),
      distribution("fastcheck.mobile_sync.scan.duration.duration_ms",
        unit: {:millisecond, :millisecond},
        tags: [:status],
        reporter_options: [buckets: scan_duration_buckets()],
        description: "Single mobile scan processing duration in milliseconds"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp request_duration_buckets, do: [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

  defp database_duration_buckets, do: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  defp scan_duration_buckets, do: [1, 5, 10, 25, 50, 100, 250, 500, 1_000]

  defp batch_duration_buckets, do: [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000]

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {FastCheckWeb, :count_users, []}
    ]
  end
end
