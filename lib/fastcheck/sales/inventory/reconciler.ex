defmodule FastCheck.Sales.Inventory.Reconciler do
  @moduledoc """
  Compares Redis hot inventory state against durable Sales Postgres facts.

  Dry-run by default. Repair requires explicit `allow_repair: true` and delegates
  mutations to `FastCheck.Sales.Inventory.Recovery`.
  """

  alias FastCheck.Sales.Inventory.DurableSnapshot
  alias FastCheck.Sales.Inventory.Recovery
  alias FastCheck.Sales.Inventory.ReservationLedger

  defmodule ReconciliationReport do
    @moduledoc false
    defstruct [
      :offer_id,
      :event_id,
      :started_at,
      :finished_at,
      :health_before,
      :health_after,
      :redis_available_before,
      :redis_available_after,
      :expected_available,
      :active_hold_count,
      :sold_count,
      :orphan_hold_count,
      :consumed_count,
      :released_count,
      :expired_count,
      :manual_review_required?,
      :dry_run?,
      :repair_applied?,
      :anomalies,
      :planned_actions,
      :applied_actions
    ]
  end

  @spec reconcile_offer(integer(), keyword()) ::
          {:ok, ReconciliationReport.t()}
          | {:manual_review_required, ReconciliationReport.t()}
          | {:error, atom() | {atom(), map()}}
  def reconcile_offer(offer_id, opts \\ []) when is_integer(offer_id) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    allow_repair? = Keyword.get(opts, :allow_repair, false)
    correlation_id = Keyword.get(opts, :correlation_id)
    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    metadata = %{
      offer_id: offer_id,
      mode: if(dry_run?, do: "dry_run", else: "repair"),
      correlation_id: correlation_id
    }

    :telemetry.execute(
      [:fastcheck, :sales, :inventory, :reconcile_started],
      %{count: 1},
      metadata
    )

    with {:ok, durable} <- DurableSnapshot.fetch(offer_id),
         {:ok, redis_before} <- fetch_redis_or_missing(offer_id),
         analysis <- analyze(durable, redis_before) do
      report =
        %ReconciliationReport{
          offer_id: offer_id,
          event_id: durable.event_id,
          started_at: started_at,
          finished_at: nil,
          health_before: health_label(redis_before),
          health_after: nil,
          redis_available_before: redis_available(redis_before),
          redis_available_after: nil,
          expected_available: max(durable.safe_available, 0),
          active_hold_count: durable.active_hold_count,
          sold_count: durable.sold_count,
          orphan_hold_count: 0,
          consumed_count: durable.sold_count,
          released_count: 0,
          expired_count: 0,
          manual_review_required?: analysis.manual_review_required?,
          dry_run?: dry_run?,
          repair_applied?: false,
          anomalies: analysis.anomalies,
          planned_actions: analysis.planned_actions,
          applied_actions: []
        }

      cond do
        analysis.manual_review_required? ->
          finished = finish_report(report, redis_before, started_at)

          :telemetry.execute(
            [:fastcheck, :sales, :inventory, :manual_review_required],
            %{count: 1},
            Map.merge(metadata, %{
              event_id: durable.event_id,
              manual_review_required: true,
              safe_available: durable.safe_available
            })
          )

          {:manual_review_required, finished}

        dry_run? or not allow_repair? ->
          finished = finish_report(report, redis_before, started_at)
          emit_reconciled(metadata, durable, finished)
          {:ok, finished}

        true ->
          case Recovery.apply_safe_repairs(offer_id, durable, analysis, opts) do
            {:ok, recovery_report} ->
              {:ok, redis_after} = fetch_redis_or_missing(offer_id)

              finished =
                report
                |> Map.put(:repair_applied?, true)
                |> Map.put(:applied_actions, recovery_report.applied_actions)
                |> Map.put(:expired_count, recovery_report.expired_count)
                |> finish_report(redis_after, started_at)

              emit_reconciled(metadata, durable, finished)
              {:ok, finished}

            {:manual_review_required, recovery_report} ->
              finished =
                report
                |> Map.put(:applied_actions, recovery_report.applied_actions)
                |> finish_report(redis_before, started_at)

              {:manual_review_required, finished}

            {:error, reason} ->
              :telemetry.execute(
                [:fastcheck, :sales, :inventory, :reconciliation_failed],
                %{count: 1},
                Map.merge(metadata, %{reason: reason})
              )

              {:error, reason}
          end
      end
    else
      {:error, :offer_not_found} = error ->
        error

      {:error, :ledger_unavailable, meta} ->
        :telemetry.execute(
          [:fastcheck, :sales, :inventory, :reconciliation_failed],
          %{count: 1},
          Map.merge(metadata, %{reason: :ledger_unavailable})
        )

        {:error, {:ledger_unavailable, meta}}
    end
  end

  defp analyze(durable, redis_before) do
    expected = max(durable.safe_available, 0)
    redis_available = redis_available(redis_before)

    drift_down? = is_integer(redis_available) and redis_available > expected
    drift_up? = is_integer(redis_available) and redis_available < expected
    missing_redis? = match?({:error, :reconciliation_required, _}, redis_before)

    manual_review_required? =
      durable.manual_review_required? or
        (drift_up? and durable.manual_review_order_count > 0)

    planned_actions =
      []
      |> maybe_action(missing_redis? and not manual_review_required?, %{
        action: :rebuild_inventory,
        target_available: expected
      })
      |> maybe_action(drift_down? and not manual_review_required?, %{
        action: :reconcile_down,
        target_available: expected
      })
      |> maybe_action(drift_up? and not manual_review_required?, %{
        action: :reconcile_up,
        target_available: expected
      })

    anomalies =
      durable.anomalies
      |> maybe_add(drift_down?, %{code: :redis_overstated_availability})
      |> maybe_add(drift_up?, %{code: :redis_understated_availability})
      |> maybe_add(missing_redis?, %{code: :missing_redis_inventory})

    %{
      manual_review_required?: manual_review_required?,
      planned_actions: planned_actions,
      anomalies: anomalies,
      expected_available: expected,
      missing_redis?: missing_redis?
    }
  end

  defp fetch_redis_or_missing(offer_id) do
    case ReservationLedger.get_availability(offer_id) do
      {:ok, _} = ok -> ok
      {:error, :reconciliation_required, meta} -> {:error, :reconciliation_required, meta}
      {:error, :ledger_unavailable, meta} -> {:error, :ledger_unavailable, meta}
      {:error, atom, meta} -> {:error, atom, meta}
    end
  end

  defp finish_report(report, redis_state, started_at) do
    %{
      report
      | finished_at: DateTime.utc_now() |> DateTime.truncate(:second),
        health_after: health_label(redis_state),
        redis_available_after: redis_available(redis_state),
        started_at: started_at
    }
  end

  defp emit_reconciled(metadata, durable, report) do
    :telemetry.execute(
      [:fastcheck, :sales, :inventory, :reconciled],
      %{count: 1},
      Map.merge(metadata, %{
        event_id: durable.event_id,
        safe_available: report.expected_available,
        redis_available: report.redis_available_after,
        sold_count: report.sold_count,
        active_hold_count: report.active_hold_count,
        manual_review_required: report.manual_review_required?
      })
    )
  end

  defp health_label({:error, :reconciliation_required, _}), do: :reconciliation_required
  defp health_label({:error, :ledger_unavailable, _}), do: :degraded
  defp health_label({:ok, %{ledger_state: state}}), do: state
  defp health_label(%{ledger_state: state}), do: state

  defp redis_available({:ok, %{available_quantity: qty}}), do: qty
  defp redis_available(%{available_quantity: qty}), do: qty
  defp redis_available(_), do: nil

  defp maybe_action(actions, false, _item), do: actions
  defp maybe_action(actions, true, item), do: actions ++ [item]

  defp maybe_add(list, false, _item), do: list
  defp maybe_add(list, true, item), do: [item | list]
end
