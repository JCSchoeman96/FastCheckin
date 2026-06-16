defmodule FastCheck.Sales.Inventory.Recovery do
  @moduledoc """
  Safe Redis inventory rebuild and stale-hold repair for FastCheck Sales.

  Mutates inventory only through `ReservationLedger`. Does not change checkout or
  order/session durable state.
  """

  alias FastCheck.Sales.Inventory.DurableSnapshot
  alias FastCheck.Sales.Inventory.ReservationLedger

  defmodule RecoveryReport do
    @moduledoc false
    defstruct [
      :offer_id,
      :event_id,
      :dry_run?,
      :repair_applied?,
      :expired_count,
      :skipped_count,
      :applied_actions,
      :manual_review_required?,
      :anomalies
    ]
  end

  @spec rebuild_offer_inventory(integer(), keyword()) ::
          {:ok, RecoveryReport.t()}
          | {:manual_review_required, RecoveryReport.t()}
          | {:error, atom() | {atom(), map()}}
  def rebuild_offer_inventory(offer_id, opts \\ []) when is_integer(offer_id) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    allow_repair? = Keyword.get(opts, :allow_repair, false)
    correlation_id = Keyword.get(opts, :correlation_id)

    :telemetry.execute(
      [:fastcheck, :sales, :inventory, :rebuild_started],
      %{count: 1},
      %{
        offer_id: offer_id,
        correlation_id: correlation_id,
        mode: mode_label(dry_run?, allow_repair?)
      }
    )

    with {:ok, durable} <- DurableSnapshot.fetch(offer_id),
         analysis <- reconciler_analysis(offer_id, durable) do
      if analysis.manual_review_required? do
        report = base_report(offer_id, durable, dry_run?, false, [])

        :telemetry.execute(
          [:fastcheck, :sales, :inventory, :manual_review_required],
          %{count: 1},
          %{offer_id: offer_id, event_id: durable.event_id, manual_review_required: true}
        )

        {:manual_review_required, report}
      else
        counts = rebuild_counts(durable, analysis.expected_available)

        if dry_run? or not allow_repair? do
          {:ok,
           base_report(offer_id, durable, true, false, [
             %{action: :rebuild_inventory, counts: counts}
           ])}
        else
          with :ok <- ReservationLedger.mark_offer_health(offer_id, :rebuilding, "rebuild"),
               :ok <- ReservationLedger.rebuild_inventory(offer_id, counts),
               :ok <- ReservationLedger.mark_offer_health(offer_id, :healthy, "rebuild_complete") do
            :telemetry.execute(
              [:fastcheck, :sales, :inventory, :rebuilt],
              %{count: 1},
              %{
                offer_id: offer_id,
                event_id: durable.event_id,
                safe_available: analysis.expected_available
              }
            )

            {:ok,
             base_report(offer_id, durable, false, true, [
               %{action: :rebuild_inventory, counts: counts}
             ])}
          else
            {:error, _atom, _meta} = error ->
              _ =
                ReservationLedger.mark_offer_health(
                  offer_id,
                  :reconciliation_required,
                  "rebuild_failed"
                )

              error
          end
        end
      end
    else
      {:error, :offer_not_found} = error -> error
      {:error, :ledger_unavailable, meta} -> {:error, {:ledger_unavailable, meta}}
    end
  end

  @spec repair_stale_holds(integer(), integer(), keyword()) ::
          {:ok, RecoveryReport.t()} | {:error, atom() | {atom(), map()}}
  def repair_stale_holds(offer_id, now, opts \\ [])
      when is_integer(offer_id) and is_integer(now) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    allow_repair? = Keyword.get(opts, :allow_repair, false)

    with {:ok, durable} <- DurableSnapshot.fetch(offer_id),
         {:ok, due_refs} <- ReservationLedger.list_due_hold_refs(offer_id, now) do
      allowed_refs = DurableSnapshot.expirable_unpaid_hold_refs(offer_id, due_refs)

      planned = %{
        action: :expire_due_holds,
        due_count: length(due_refs),
        allowed_count: length(allowed_refs),
        allowed_refs: allowed_refs
      }

      if dry_run? or not allow_repair? do
        {:ok, base_report(offer_id, durable, true, false, [planned])}
      else
        case ReservationLedger.expire_due_holds_for_offer(offer_id, now,
               allowed_refs: allowed_refs
             ) do
          {:ok, %{expired_count: expired, skipped_count: skipped}} ->
            {:ok,
             %RecoveryReport{
               offer_id: offer_id,
               event_id: durable.event_id,
               dry_run?: false,
               repair_applied?: true,
               expired_count: expired,
               skipped_count: skipped,
               applied_actions: [Map.put(planned, :expired_count, expired)],
               manual_review_required?: false,
               anomalies: []
             }}

          {:error, :ledger_unavailable, meta} ->
            {:error, {:ledger_unavailable, meta}}
        end
      end
    end
  end

  @doc false
  @spec apply_safe_repairs(integer(), map(), map(), keyword()) ::
          {:ok, RecoveryReport.t()}
          | {:manual_review_required, RecoveryReport.t()}
          | {:error, atom() | {atom(), map()}}
  def apply_safe_repairs(offer_id, durable, analysis, opts) do
    allow_repair? = Keyword.get(opts, :allow_repair, false)

    if not allow_repair? or analysis.manual_review_required? do
      {:manual_review_required, base_report(offer_id, durable, true, false, [])}
    else
      counts = rebuild_counts(durable, analysis.expected_available)

      with :ok <- ReservationLedger.mark_offer_health(offer_id, :rebuilding, "reconcile"),
           :ok <- ReservationLedger.rebuild_inventory(offer_id, counts),
           :ok <- ReservationLedger.mark_offer_health(offer_id, :healthy, "reconcile_complete") do
        {:ok,
         base_report(offer_id, durable, false, true, [
           %{action: :rebuild_inventory, counts: counts}
         ])}
      else
        {:error, _atom, _meta} = error ->
          _ =
            ReservationLedger.mark_offer_health(
              offer_id,
              :reconciliation_required,
              "reconcile_failed"
            )

          error
      end
    end
  end

  defp reconciler_analysis(offer_id, durable) do
    expected = max(durable.safe_available, 0)

    %{
      manual_review_required?: durable.manual_review_required?,
      expected_available: expected,
      missing_redis?:
        match?(
          {:error, :reconciliation_required, _},
          ReservationLedger.get_availability(offer_id)
        )
    }
  end

  defp rebuild_counts(durable, expected_available) do
    %{
      configured_quantity: durable.configured_quantity,
      available_quantity: expected_available,
      reserved_quantity: durable.active_hold_count,
      consumed_quantity: durable.sold_count,
      ledger_state: :healthy
    }
  end

  defp base_report(offer_id, durable, dry_run?, applied?, actions) do
    %RecoveryReport{
      offer_id: offer_id,
      event_id: durable.event_id,
      dry_run?: dry_run?,
      repair_applied?: applied?,
      expired_count: 0,
      skipped_count: 0,
      applied_actions: actions,
      manual_review_required?: durable.manual_review_required?,
      anomalies: durable.anomalies
    }
  end

  defp mode_label(true, _), do: "dry_run"
  defp mode_label(false, true), do: "repair"
  defp mode_label(false, false), do: "dry_run"
end
