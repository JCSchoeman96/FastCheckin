defmodule FastCheck.Sales.Payments.PaymentBoundaryTest do
  use ExUnit.Case, async: true

  @forbidden ~w(
    TicketIssue
    Attendee
    IssueTicketsWorker
    DeliveryAttempt
    WhatsApp
  )

  @handler_source File.read!("lib/fastcheck/sales/payments/payment_outcome_handler.ex")
  @outcomes_source File.read!("lib/fastcheck/sales/payments/payment_outcomes.ex")

  test "outcome handler does not reference forbidden issuance domains" do
    for term <- @forbidden do
      refute String.contains?(@handler_source, term)
      refute String.contains?(@outcomes_source, term)
    end
  end

  test "outcome modules live under Sales payments namespace" do
    assert Code.ensure_loaded?(FastCheck.Sales.Payments.PaymentOutcomes)
    assert Code.ensure_loaded?(FastCheck.Sales.Payments.PaymentOutcomeHandler)
    assert Code.ensure_loaded?(FastCheck.Sales.Payments.PaymentFailureReason)
    assert Code.ensure_loaded?(FastCheck.Sales.Payments.OutcomeBroadcast)
    assert Code.ensure_loaded?(FastCheck.Sales.Payments.LatePaymentRecovery)
  end
end
