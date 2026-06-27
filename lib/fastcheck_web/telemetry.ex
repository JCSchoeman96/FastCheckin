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

      # Sales operational metrics
      counter("fastcheck.sales.checkout.reserved.count",
        tags: [:status, :source_channel],
        description: "Sales checkout reservations"
      ),
      counter("fastcheck.sales.checkout.expired.count",
        tags: [:status, :source_channel],
        description: "Sales checkout expirations"
      ),
      counter("fastcheck.sales.checkout.released.count",
        tags: [:status, :source_channel],
        description: "Sales checkout hold releases"
      ),
      counter("fastcheck.sales.payment.initialized.count",
        tags: [:status, :source_channel, :provider],
        description: "Sales payment initializations"
      ),
      counter("fastcheck.sales.payment.webhook_received.count",
        tags: [:status, :provider],
        description: "Sales payment webhooks received"
      ),
      counter("fastcheck.sales.payment.verified.count",
        tags: [:status, :source_channel, :provider],
        description: "Sales payment verifications"
      ),
      counter("fastcheck.sales.payment.mismatch.count",
        tags: [:status, :source_channel, :provider, :reason_code],
        description: "Sales payment mismatches"
      ),
      counter("fastcheck.sales.payment.failed.count",
        tags: [:status, :source_channel, :provider, :reason_code],
        description: "Sales payment failures"
      ),
      counter("fastcheck.sales.ticket.issued.count",
        tags: [:status, :source_channel],
        description: "Sales tickets issued"
      ),
      counter("fastcheck.sales.ticket.issue_failed.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales ticket issuance failures"
      ),
      counter("fastcheck.sales.ticket.revoked.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales tickets revoked"
      ),
      counter("fastcheck.sales.ticket.revocation_started.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales ticket revocations started"
      ),
      counter("fastcheck.sales.ticket.revocation_idempotent.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales ticket revocation idempotent retries"
      ),
      counter("fastcheck.sales.ticket.revocation_failed.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales ticket revocation failures"
      ),
      counter("fastcheck.sales.scanner_visibility.sync_queued.count",
        tags: [:status, :reason_code],
        description: "Sales scanner visibility sync queued"
      ),
      counter("fastcheck.sales.scanner_visibility.invalidation_appended.count",
        tags: [:status, :reason_code],
        description: "Sales scanner visibility invalidations appended"
      ),
      counter("fastcheck.sales.delivery.queued.count",
        tags: [:status, :source_channel, :provider],
        description: "Sales delivery attempts queued"
      ),
      counter("fastcheck.sales.delivery.sent.count",
        tags: [:status, :source_channel, :provider],
        description: "Sales delivery attempts sent"
      ),
      counter("fastcheck.sales.delivery.failed.count",
        tags: [:status, :source_channel, :provider, :reason_code],
        description: "Sales delivery attempts failed"
      ),
      counter("fastcheck.sales.manual_review.opened.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales manual review opened"
      ),
      counter("fastcheck.sales.manual_review.closed.count",
        tags: [:status, :source_channel, :reason_code],
        description: "Sales manual review closed"
      ),
      counter("fastcheck.sales.inventory.reserved.count",
        tags: [:status, :source_channel],
        description: "Sales inventory reservations"
      ),
      counter("fastcheck.sales.inventory.consumed.count",
        tags: [:status, :source_channel],
        description: "Sales inventory consumes"
      ),
      counter("fastcheck.sales.inventory.released.count",
        tags: [:status, :source_channel],
        description: "Sales inventory releases"
      ),
      counter("fastcheck.sales.inventory.reconciled.count",
        tags: [:status, :reason_code],
        description: "Sales inventory reconciliation"
      ),
      counter("fastcheck.sales.whatsapp.inbound_received.count",
        tags: [:status, :source_channel],
        description: "Sales WhatsApp inbound messages"
      ),
      counter("fastcheck.sales.whatsapp.outbound_sent.count",
        tags: [:status, :source_channel],
        description: "Sales WhatsApp outbound messages"
      ),
      counter("fastcheck.sales.admin.revocation_requested.count",
        tags: [:status, :reason_code],
        description: "Sales admin revocation requests"
      ),
      counter("fastcheck.sales.admin.revocation_completed.count",
        tags: [:status, :reason_code],
        description: "Sales admin revocations completed"
      ),
      counter("fastcheck.sales.admin.revocation_failed.count",
        tags: [:status, :reason_code],
        description: "Sales admin revocation failures"
      ),
      counter("fastcheck.sales.admin.refund_marked.count",
        tags: [:status, :reason_code],
        description: "Sales admin refund markers"
      ),
      counter("fastcheck.sales.admin.action_denied.count",
        tags: [:status, :reason_code],
        description: "Sales admin action denials"
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
