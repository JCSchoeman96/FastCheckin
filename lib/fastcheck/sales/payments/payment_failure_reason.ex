defmodule FastCheck.Sales.Payments.PaymentFailureReason do
  @moduledoc """
  Stable machine-readable reason codes for Sales payment outcome handling.

  VS-07C uses these codes for manual_review transitions, audit metadata, and
  telemetry. Do not embed raw provider payloads or PII in reason strings.
  """

  @payment_amount_mismatch "payment_amount_mismatch"
  @payment_currency_mismatch "payment_currency_mismatch"
  @payment_reference_mismatch "payment_reference_mismatch"
  @payment_provider_failed "payment_provider_failed"
  @payment_provider_pending_timeout "payment_provider_pending_timeout"
  @payment_event_unmatched "payment_event_unmatched"
  @payment_duplicate_suspicious "payment_duplicate_suspicious"
  @late_payment_inventory_unavailable "late_payment_inventory_unavailable"
  @late_payment_inventory_ledger_unhealthy "late_payment_inventory_ledger_unhealthy"
  @late_payment_recovery_failed "late_payment_recovery_failed"
  @payment_raw_payload_invalid "payment_raw_payload_invalid"
  @payment_state_conflict "payment_state_conflict"
  @payment_manual_operator_review_required "payment_manual_operator_review_required"

  def payment_amount_mismatch, do: @payment_amount_mismatch
  def payment_currency_mismatch, do: @payment_currency_mismatch
  def payment_reference_mismatch, do: @payment_reference_mismatch
  def payment_provider_failed, do: @payment_provider_failed
  def payment_provider_pending_timeout, do: @payment_provider_pending_timeout
  def payment_event_unmatched, do: @payment_event_unmatched
  def payment_duplicate_suspicious, do: @payment_duplicate_suspicious
  def late_payment_inventory_unavailable, do: @late_payment_inventory_unavailable
  def late_payment_inventory_ledger_unhealthy, do: @late_payment_inventory_ledger_unhealthy
  def late_payment_recovery_failed, do: @late_payment_recovery_failed
  def payment_raw_payload_invalid, do: @payment_raw_payload_invalid
  def payment_state_conflict, do: @payment_state_conflict
  def payment_manual_operator_review_required, do: @payment_manual_operator_review_required

  @doc false
  def all do
    [
      @payment_amount_mismatch,
      @payment_currency_mismatch,
      @payment_reference_mismatch,
      @payment_provider_failed,
      @payment_provider_pending_timeout,
      @payment_event_unmatched,
      @payment_duplicate_suspicious,
      @late_payment_inventory_unavailable,
      @late_payment_inventory_ledger_unhealthy,
      @late_payment_recovery_failed,
      @payment_raw_payload_invalid,
      @payment_state_conflict,
      @payment_manual_operator_review_required
    ]
  end
end
