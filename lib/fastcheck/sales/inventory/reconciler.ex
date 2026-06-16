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

    case DurableSnapshot.fetch(offer_id) do
      {:ok, durable} ->
        redis_before = fetch_redis_state(offer_id)

        case redis_before do
          {:error, :ledger_unavailable, meta} ->
            :telemetry.execute(
              [:fastcheck, :sales, :inventory, :reconciliation_failed],
              %{count: 1},
              Map.merge(metadata, %{reason: :ledger_unavailable})
            )

            {:error, {:ledger_unavailable, meta}}

          redis_state ->
            analysis = analyze(durable, redis_state)
            report = build_report(durable, analysis, redis_state, started_at, dry_run?)

            cond do
              analysis.manual_review_required? ->
                {:manual_review_required,
                 finish_manual_review(
                   report,
                   redis_state,
                   started_at,
                   metadata,
                   durable,
                   analysis
                 )}

              dry_run? or not allow_repair? ->
                finished = finish_report(report, redis_state, started_at)
                emit_reconciled(metadata, durable, finished)
                {:ok, finished}

              true ->
                apply_repair_path(
                  offer_id,
                  durable,
                  analysis,
                  report,
                  redis_state,
                  started_at,
                  metadata,
                  opts
                )
            end
        end

      {:error, :offer_not_found} = error ->
        error
    end
  end

  defp build_report(durable, analysis, redis_state, started_at, dry_run?) do
    %ReconciliationReport{
      offer_id: durable.offer_id,
      event_id: durable.event_id,
      started_at: started_at,
      finished_at: nil,
      health_before: health_label(redis_state),
      health_after: nil,
      redis_available_before: redis_available(redis_state),
      redis_available_after: nil,
      expected_available: max(durable.safe_available, 0),
      active_hold_count: durable.active_hold_count,
      sold_count: durable.sold_count,
      orphan_hold_count: analysis.orphan_hold_count,
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
  end

  defp finish_manual_review(report, redis_state, started_at, metadata, durable, analysis) do
    finished = finish_report(report, redis_state, started_at)

    :telemetry.execute(
      [:fastcheck, :sales, :inventory, :manual_review_required],
      %{count: 1},
      Map.merge(metadata, %{
        event_id: durable.event_id,
        manual_review_required: true,
        safe_available: durable.safe_available,
        orphan_hold_count: analysis.orphan_hold_count
      })
    )

    finished
  end

  defp apply_repair_path(
         offer_id,
         durable,
         analysis,
         report,
         redis_state,
         started_at,
         metadata,
         opts
       ) do
    case Recovery.apply_safe_repairs(offer_id, durable, analysis, opts) do
      {:ok, recovery_report} ->
        redis_after = fetch_redis_state(offer_id)

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
          |> finish_report(redis_state, started_at)

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

  defp analyze(durable, redis_before) do
    expected = max(durable.safe_available, 0)
    redis_available = redis_available(redis_before)
    orphan_hold_count = orphan_hold_count(durable.offer_id)

    drift_down? = is_integer(redis_available) and redis_available > expected
    drift_up? = is_integer(redis_available) and redis_available < expected
    missing_redis? = match?({:error, :reconciliation_required, _}, redis_before)
    orphan_holds? = orphan_hold_count > 0

    manual_review_required? =
      durable.manual_review_required? or
        orphan_holds? or
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
      |> maybe_add(orphan_holds?, %{code: :orphan_redis_holds, count: orphan_hold_count})

    %{
      manual_review_required?: manual_review_required?,
      planned_actions: planned_actions,
      anomalies: anomalies,
      expected_available: expected,
      missing_redis?: missing_redis?,
      orphan_hold_count: orphan_hold_count
    }
  end

  defp orphan_hold_count(offer_id) do
    with {:ok, redis_refs} <- ReservationLedger.list_hold_refs(offer_id),
         {:ok, durable_refs} <- DurableSnapshot.order_public_references(offer_id) do
      redis_refs
      |> Enum.reject(&MapSet.member?(durable_refs, &1))
      |> length()
    else
      _ -> 0
    end
  end

  defp fetch_redis_state(offer_id) do
    ReservationLedger.get_availability(offer_id)
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
        orphan_hold_count: report.orphan_hold_count,
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
