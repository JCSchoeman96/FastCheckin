defmodule FastCheck.Operations do
  @moduledoc """
  Operations-facing boundary for LiveView dashboards and reconciliation.
  """

  alias FastCheck.Operations.{ActivityFeed, ConflictService, MetricsService}

  defdelegate broadcast_scan_summary(event_id, gate_id, payload), to: ActivityFeed
  defdelegate broadcast_conflict_count(event_id, count), to: ConflictService
  defdelegate broadcast_device_health(event_id, payload), to: MetricsService
end
