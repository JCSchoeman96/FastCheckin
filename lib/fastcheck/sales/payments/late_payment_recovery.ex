defmodule FastCheck.Sales.Payments.LatePaymentRecovery do
  @moduledoc """
  Coordinates late-payment inventory recovery for expired checkout sessions.

  Runs Redis reservation steps in a compensation-safe order: reserve, durable
  paid-state transitions, then consume. Releases reserved holds when Postgres
  transitions fail before payment is recorded. Once payment is recorded, consume
  failures preserve the hold and mark inventory reconciliation.
  """

  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Payments.PaymentFailureReason, as: Reasons
  alias FastCheck.Sales.Payments.PaymentOutcomes

  @retryable_consume_errors [:ledger_unavailable, :lock_timeout]

  @type ctx :: %{
          offer_id: integer(),
          order_ref: String.t(),
          quantity: integer(),
          ttl_seconds: pos_integer(),
          reserve_key: String.t(),
          consume_key: String.t(),
          release_key: String.t(),
          stage: :none | :reserved | :paid | :consumed | :released
        }

  @type paid_result :: term()

  @doc """
  Reserves inventory, applies the caller's paid-state transition, then consumes.

  Returns `{:ok, paid_result}` on full success.

  On reserve failure returns `{:error, :manual_review, reason_code}`.

  On paid-state failure returns `{:error, :manual_review, reason_code}` after
  releasing any reserved hold.

  On consume failure after paid-state success returns
  `{:error, :paid_reconciliation_required, reason_code, paid_result}` without
  releasing the hold, because payment is authoritative at that point.
  """
  @spec recover(ctx(), (-> {:ok, paid_result()} | {:error, term()})) ::
          {:ok, paid_result()}
          | {:error, :manual_review, String.t()}
          | {:error, :retryable}
          | {:error, :paid_reconciliation_required, String.t(), paid_result()}
          | {:error, :paid_retryable, atom(), paid_result()}
  def recover(ctx, mark_paid_fun) when is_function(mark_paid_fun, 0) do
    with {:ok, ctx} <- reserve(ctx),
         {:ok, paid_result, ctx} <- mark_paid(ctx, mark_paid_fun),
         ctx = %{ctx | stage: :paid},
         :ok <- consume(ctx, paid_result) do
      {:ok, paid_result}
    end
  end

  @doc false
  def build_ctx(attempt_id, offer_id, order_ref, quantity) do
    %{
      offer_id: offer_id,
      order_ref: order_ref,
      quantity: quantity,
      ttl_seconds: Application.get_env(:fastcheck, :sales_checkout_hold_ttl_seconds, 600),
      reserve_key: PaymentOutcomes.late_recovery_reserve_key(attempt_id),
      consume_key: PaymentOutcomes.late_recovery_consume_key(attempt_id),
      release_key: PaymentOutcomes.late_recovery_release_key(attempt_id),
      stage: :none
    }
  end

  @doc false
  def reserved?(ctx), do: ctx.stage == :reserved

  defp reserve(%{offer_id: offer_id, order_ref: order_ref, quantity: quantity} = ctx) do
    reserve_key = ctx.reserve_key
    ttl = ctx.ttl_seconds

    case ReservationLedger.reserve_for_late_payment_recovery(
           offer_id,
           order_ref,
           quantity,
           ttl,
           reserve_key,
           ctx.release_key
         ) do
      {:ok, _held} ->
        {:ok, %{ctx | stage: :reserved}}

      {:error, :already_consumed, _meta} ->
        accept_exact_consumed_hold(ctx)

      {:error, error, _meta} when error in [:ledger_unavailable, :lock_timeout] ->
        {:error, :retryable}

      {:error, error, _meta} ->
        manual_review_error(error)
    end
  end

  defp accept_exact_consumed_hold(ctx) do
    case ReservationLedger.get_hold_detail(ctx.offer_id, ctx.order_ref) do
      {:ok,
       %{
         offer_id: offer_id,
         order_public_reference: order_ref,
         quantity: quantity,
         status: :consumed
       }}
      when offer_id == ctx.offer_id and order_ref == ctx.order_ref and
             quantity == ctx.quantity ->
        {:ok, %{ctx | stage: :reserved}}

      {:ok, _detail} ->
        manual_review_error(:already_consumed)

      {:error, :ledger_unavailable, _meta} ->
        {:error, :retryable}
    end
  end

  defp mark_paid(%{stage: :reserved} = ctx, mark_paid_fun) do
    case invoke_mark_paid_fun(mark_paid_fun) do
      {:ok, paid_result} ->
        {:ok, paid_result, ctx}

      {:error, _reason} ->
        case release_reserved(ctx) do
          :ok ->
            {:error, :manual_review, Reasons.late_payment_recovery_failed()}

          {:error, :retryable} ->
            {:error, :retryable}

          {:error, _reason} ->
            case mark_reconciliation_required(ctx.offer_id, "late_payment_release_failed") do
              :ok ->
                {:error, :manual_review, Reasons.late_payment_inventory_ledger_unhealthy()}

              {:error, _error, _metadata} ->
                {:error, :retryable}
            end
        end
    end
  end

  defp consume(%{stage: :paid} = ctx, paid_result) do
    %{offer_id: offer_id, order_ref: order_ref, quantity: quantity} = ctx

    consume_result =
      case Application.get_env(:fastcheck, :late_payment_recovery_consume_fun) do
        fun when is_function(fun, 1) ->
          fun.(ctx)

        _ ->
          ReservationLedger.consume(offer_id, order_ref, quantity, ctx.consume_key)
      end

    case consume_result do
      {:ok, _consumed} ->
        :ok

      {:error, error, _meta} when error in @retryable_consume_errors ->
        {:error, :paid_retryable, error, paid_result}

      {:error, error, _meta} ->
        _ = mark_reconciliation_required(offer_id, "late_payment_consume_failed")

        {:error, :paid_reconciliation_required, paid_reconciliation_reason(error), paid_result}
    end
  end

  defp release_reserved(%{stage: stage} = ctx) when stage in [:reserved, :paid] do
    case ReservationLedger.release_late_payment_reservation(
           ctx.offer_id,
           ctx.order_ref,
           ctx.quantity,
           ctx.reserve_key,
           ctx.release_key
         ) do
      {:ok, _} ->
        :ok

      {:error, error, _} when error in [:ledger_unavailable, :lock_timeout] ->
        {:error, :retryable}

      {:error, error, _} ->
        {:error, error}
    end
  end

  defp release_reserved(_ctx), do: :ok

  defp mark_reconciliation_required(offer_id, reason) do
    ReservationLedger.mark_offer_health(offer_id, :reconciliation_required, reason)
  end

  defp manual_review_error(error) when error in [:ledger_unavailable, :reconciliation_required] do
    {:error, :manual_review, Reasons.late_payment_inventory_ledger_unhealthy()}
  end

  defp manual_review_error(error)
       when error in [
              :insufficient_inventory,
              :hold_not_found,
              :hold_expired,
              :invalid_quantity,
              :already_consumed
            ] do
    {:error, :manual_review, Reasons.late_payment_inventory_unavailable()}
  end

  defp manual_review_error(_error) do
    {:error, :manual_review, Reasons.late_payment_recovery_failed()}
  end

  defp paid_reconciliation_reason(error)
       when error in [:ledger_unavailable, :reconciliation_required, :ledger_degraded] do
    Reasons.late_payment_inventory_ledger_unhealthy()
  end

  defp paid_reconciliation_reason(_error) do
    Reasons.late_payment_inventory_ledger_unhealthy()
  end

  defp invoke_mark_paid_fun(mark_paid_fun) do
    case Application.get_env(:fastcheck, :late_payment_recovery_mark_paid_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> mark_paid_fun.()
    end
  end
end
