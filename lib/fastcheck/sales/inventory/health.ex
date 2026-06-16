defmodule FastCheck.Sales.Inventory.Health do
  @moduledoc """
  Read-only inventory health checks for FastCheck Sales offers.

  Compares Redis hot ledger state against durable snapshot hints without mutating
  inventory or checkout state.
  """

  alias FastCheck.Sales.Inventory.DurableSnapshot
  alias FastCheck.Sales.Inventory.ReservationLedger

  defmodule HealthReport do
    @moduledoc false
    defstruct [
      :offer_id,
      :event_id,
      :redis_present?,
      :ledger_state,
      :redis_available,
      :redis_reserved,
      :redis_consumed,
      :configured_quantity,
      :sold_count,
      :active_hold_count,
      :safe_available,
      :drift_detected?,
      :manual_review_required?,
      :status,
      :anomalies
    ]
  end

  @type health_report :: HealthReport.t()

  @spec offer_health(integer()) :: {:ok, HealthReport.t()} | {:error, atom()}
  def offer_health(offer_id) when is_integer(offer_id) do
    :telemetry.execute(
      [:fastcheck, :sales, :inventory, :health_checked],
      %{count: 1},
      %{offer_id: offer_id}
    )

    case DurableSnapshot.fetch(offer_id) do
      {:ok, durable} ->
        redis_result = ReservationLedger.get_availability(offer_id)
        report = build_report(offer_id, durable, redis_result)

        if report.manual_review_required? do
          :telemetry.execute(
            [:fastcheck, :sales, :inventory, :manual_review_required],
            %{count: 1},
            %{
              offer_id: offer_id,
              event_id: durable.event_id,
              manual_review_required: true
            }
          )
        end

        {:ok, report}

      {:error, :offer_not_found} = error ->
        error
    end
  end

  defp build_report(offer_id, durable, {:error, :reconciliation_required, _meta}) do
    %HealthReport{
      offer_id: offer_id,
      event_id: durable.event_id,
      redis_present?: false,
      ledger_state: :reconciliation_required,
      redis_available: nil,
      redis_reserved: nil,
      redis_consumed: nil,
      configured_quantity: durable.configured_quantity,
      sold_count: durable.sold_count,
      active_hold_count: durable.active_hold_count,
      safe_available: durable.safe_available,
      drift_detected?: true,
      manual_review_required?: durable.manual_review_required?,
      status: :missing_redis_inventory,
      anomalies: [%{code: :missing_redis_inventory} | durable.anomalies]
    }
  end

  defp build_report(offer_id, durable, {:error, :ledger_unavailable, _meta}) do
    %HealthReport{
      offer_id: offer_id,
      event_id: durable.event_id,
      redis_present?: false,
      ledger_state: :degraded,
      redis_available: nil,
      redis_reserved: nil,
      redis_consumed: nil,
      configured_quantity: durable.configured_quantity,
      sold_count: durable.sold_count,
      active_hold_count: durable.active_hold_count,
      safe_available: durable.safe_available,
      drift_detected?: true,
      manual_review_required?: true,
      status: :ledger_unavailable,
      anomalies: [%{code: :ledger_unavailable} | durable.anomalies]
    }
  end

  defp build_report(offer_id, durable, {:ok, redis}) do
    drift? = redis.available_quantity != max(durable.safe_available, 0)
    manual_review? = durable.manual_review_required? or drift_with_ambiguity?(durable, redis)

    status =
      cond do
        manual_review? -> :manual_review_required
        drift? -> :drift_detected
        redis.ledger_state in [:degraded, :reconciliation_required, :closed] -> redis.ledger_state
        true -> :healthy
      end

    %HealthReport{
      offer_id: offer_id,
      event_id: durable.event_id,
      redis_present?: true,
      ledger_state: redis.ledger_state,
      redis_available: redis.available_quantity,
      redis_reserved: redis.reserved_quantity,
      redis_consumed: redis.consumed_quantity,
      configured_quantity: durable.configured_quantity,
      sold_count: durable.sold_count,
      active_hold_count: durable.active_hold_count,
      safe_available: durable.safe_available,
      drift_detected?: drift?,
      manual_review_required?: manual_review?,
      status: status,
      anomalies: durable.anomalies
    }
  end

  defp drift_with_ambiguity?(durable, redis) do
    durable.safe_available < 0 or
      (redis.available_quantity > max(durable.safe_available, 0) and
         durable.manual_review_required?)
  end
end
