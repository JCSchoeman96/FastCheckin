defmodule FastCheck.Sales.Payments.LatePaymentRecovery do
  @moduledoc """
  Coordinates late-payment inventory recovery for expired checkout sessions.

  Re-establishes a held reservation before applying the caller's paid-state
  transition. Final inventory consumption belongs to PaidOrderFulfillment, after
  the transaction containing the verified-paid state and durable worker handoff
  has committed.
  """

  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Payments.PaymentFailureReason, as: Reasons
  alias FastCheck.Sales.Payments.PaymentOutcomes

  @type ctx :: %{
          offer_id: integer(),
          order_ref: String.t(),
          quantity: integer(),
          ttl_seconds: pos_integer(),
          reserve_key: String.t(),
          consume_key: String.t(),
          release_key: String.t(),
          stage: :none | :reserved | :released
        }

  @type paid_result :: term()

  @doc """
  Reserves inventory and applies the caller's paid-state transition.

  Returns `{:ok, paid_result}` while leaving the hold held for
  `PaidOrderFulfillment` to consume after the paid-state transaction commits.

  On reserve failure returns `{:error, :manual_review, reason_code}`.

  On paid-state failure returns `{:error, :manual_review, reason_code}` after
  releasing any reserved hold.

  """
  @spec recover(ctx(), (-> {:ok, paid_result()} | {:error, term()})) ::
          {:ok, paid_result()}
          | {:error, :manual_review, String.t()}
          | {:error, :retryable}
  def recover(ctx, mark_paid_fun) when is_function(mark_paid_fun, 0) do
    with {:ok, ctx} <- reserve(ctx) do
      mark_paid(ctx, mark_paid_fun)
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
        {:ok, paid_result}

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

  defp release_reserved(%{stage: :reserved} = ctx) do
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

  defp invoke_mark_paid_fun(mark_paid_fun) do
    case Application.get_env(:fastcheck, :late_payment_recovery_mark_paid_fun) do
      fun when is_function(fun, 0) -> fun.()
      _ -> mark_paid_fun.()
    end
  end
end
