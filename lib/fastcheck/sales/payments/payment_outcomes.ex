defmodule FastCheck.Sales.Payments.PaymentOutcomes do
  @moduledoc """
  Pure Sales payment outcome classification after Paystack server-side verification.

  Determines deterministic business outcomes from provider verify results and durable
  local state. Does not mutate Ash resources, call Paystack HTTP, or touch Redis.
  """

  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.PaymentFailureReason, as: Reasons

  @terminal_failed_provider_statuses ~w(failed abandoned reversed)
  @payable_order_statuses ~w(awaiting_payment payment_pending paid_unverified)
  @eligible_session_statuses ~w(payment_link_sent payment_started)

  @type outcome ::
          :verified_active_checkout
          | :late_payment_recovery_required
          | :duplicate_already_verified
          | :amount_mismatch
          | :currency_mismatch
          | :reference_mismatch
          | :provider_failed
          | :provider_pending_or_abandoned
          | :manual_review_required

  @type classify_result ::
          {:ok, outcome(), map()}
          | {:error, :retryable}
          | {:error, term()}

  @doc """
  Classifies a Paystack verify result against durable local payment state.
  """
  @spec classify_provider_result(map(), PaymentAttempt.t(), Order.t(), CheckoutSession.t()) ::
          classify_result()
  def classify_provider_result(result, attempt, order, session) do
    provider_status = normalize_status(result.provider_status)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    base_attrs = build_base_attrs(result, attempt, now)

    case provider_status do
      "success" ->
        classify_success(result, attempt, order, session, base_attrs, now)

      status when status in @terminal_failed_provider_statuses ->
        {:ok, :provider_failed, provider_failed_attrs(base_attrs, status)}

      _ ->
        {:error, :retryable}
    end
  end

  defp build_base_attrs(result, attempt, now) do
    %{
      provider_status: result.provider_status,
      last_verified_at: now,
      raw_verify_response: result.safe_data || %{},
      local_amount_cents: attempt.amount_cents,
      provider_amount_cents: normalize_amount(result.amount),
      local_currency: normalize_currency(attempt.currency),
      provider_currency: normalize_currency(result.currency)
    }
  end

  defp provider_failed_attrs(base_attrs, provider_status) do
    Map.merge(base_attrs, %{
      reason_code: Reasons.payment_provider_failed(),
      failure_code: "provider_status_#{provider_status}",
      failure_message: "Paystack reported #{provider_status}"
    })
  end

  defp classify_success(result, attempt, order, session, base_attrs, now) do
    cond do
      reference_mismatch?(result, attempt) ->
        {:ok, :reference_mismatch, reference_mismatch_attrs(base_attrs)}

      amount_mismatch?(result, attempt, order) ->
        {:ok, :amount_mismatch, mismatch_attrs(base_attrs, Reasons.payment_amount_mismatch())}

      currency_mismatch?(result, attempt, order) ->
        {:ok, :currency_mismatch, mismatch_attrs(base_attrs, Reasons.payment_currency_mismatch())}

      order.status == "paid_verified" ->
        {:ok, :duplicate_already_verified,
         Map.merge(base_attrs, %{reason_code: Reasons.payment_duplicate_suspicious()})}

      true ->
        classify_verified_success(result, session, order, base_attrs, now)
    end
  end

  defp reference_mismatch_attrs(base_attrs) do
    Map.merge(base_attrs, %{
      reason_code: Reasons.payment_reference_mismatch(),
      manual_review_reason: Reasons.payment_reference_mismatch(),
      failure_code: "reference_mismatch",
      failure_message: "Provider reference mismatch"
    })
  end

  defp mismatch_attrs(base_attrs, reason_code) do
    Map.merge(base_attrs, %{
      reason_code: reason_code,
      manual_review_reason: reason_code
    })
  end

  defp classify_verified_success(result, session, order, base_attrs, now) do
    paid_at = parse_paid_at(result.paid_at) || now

    success_attrs =
      Map.merge(base_attrs, %{
        provider_paid_at: paid_at,
        verified_at: now
      })

    case checkout_context(session, order) do
      :active ->
        {:ok, :verified_active_checkout, success_attrs}

      :expired_or_ineligible ->
        {:ok, :late_payment_recovery_required, success_attrs}

      :already_paid ->
        {:ok, :duplicate_already_verified,
         Map.merge(success_attrs, %{reason_code: Reasons.payment_duplicate_suspicious()})}
    end
  end

  @doc """
  Returns `:active`, `:expired_or_ineligible`, or `:already_paid` for a verified success path.
  """
  @spec checkout_context(CheckoutSession.t(), Order.t()) ::
          :active | :expired_or_ineligible | :already_paid
  def checkout_context(%CheckoutSession{status: session_status}, %Order{status: order_status}) do
    cond do
      order_status == "paid_verified" ->
        :already_paid

      session_status in @eligible_session_statuses and order_status in @payable_order_statuses ->
        :active

      session_status == "expired" or order_status == "expired" ->
        :expired_or_ineligible

      session_status == "paid" ->
        :already_paid

      true ->
        :expired_or_ineligible
    end
  end

  @spec late_recovery_reserve_key(integer()) :: String.t()
  def late_recovery_reserve_key(payment_attempt_id),
    do: "late_recovery:reserve:#{payment_attempt_id}"

  @spec late_recovery_release_key(integer()) :: String.t()
  def late_recovery_release_key(payment_attempt_id),
    do: "late_recovery:release:#{payment_attempt_id}"

  @spec late_recovery_consume_key(integer()) :: String.t()
  def late_recovery_consume_key(payment_attempt_id),
    do: "late_recovery:consume:#{payment_attempt_id}"

  defp reference_mismatch?(result, attempt) do
    case normalize_provider_reference(result.provider_reference) do
      nil ->
        true

      provider_reference ->
        provider_reference != normalize_provider_reference(attempt.provider_reference)
    end
  end

  defp amount_mismatch?(result, attempt, order) do
    provider_amount = normalize_amount(result.amount)
    provider_amount != attempt.amount_cents or provider_amount != order.total_amount_cents
  end

  defp currency_mismatch?(result, attempt, order) do
    provider_currency = normalize_currency(result.currency)

    provider_currency != normalize_currency(attempt.currency) or
      provider_currency != normalize_currency(order.currency)
  end

  defp normalize_provider_reference(reference) when is_binary(reference) do
    reference = String.trim(reference)
    if reference == "", do: nil, else: reference
  end

  defp normalize_provider_reference(_reference), do: nil

  defp normalize_amount(amount) when is_integer(amount), do: amount

  defp normalize_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_amount(_), do: nil

  defp normalize_currency(currency) when is_binary(currency), do: String.upcase(currency)
  defp normalize_currency(_), do: nil

  defp normalize_status(status) when is_binary(status), do: String.downcase(status)
  defp normalize_status(_), do: "unknown"

  defp parse_paid_at(nil), do: nil

  defp parse_paid_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_paid_at(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp parse_paid_at(_), do: nil
end
