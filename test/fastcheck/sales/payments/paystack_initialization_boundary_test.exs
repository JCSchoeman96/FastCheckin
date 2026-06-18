defmodule FastCheck.Sales.Payments.PaystackInitializationBoundaryTest do
  use ExUnit.Case, async: true

  @orchestrator_path "lib/fastcheck/sales/payments/transaction_initialization.ex"

  @forbidden_tokens [
    "TransactionVerifier",
    "WebhookVerifier",
    "PaymentEvent",
    "TicketIssue",
    "DeliveryAttempt",
    "IssueTickets",
    "FastCheck.Tickets",
    "Attendee",
    "WhatsApp",
    "Redix",
    "sales:offer:",
    "mark_paid",
    "mark_verified",
    "mark_webhook_received",
    "queue_fulfillment"
  ]

  test "initialization orchestrator does not couple to verification, ticketing, or inventory" do
    source = File.read!(@orchestrator_path)

    for token <- @forbidden_tokens do
      refute String.contains?(source, token),
             "#{@orchestrator_path} must not reference #{token} in VS-06C scope"
    end

    assert source =~ "FastCheck.Payments.Paystack.TransactionInitializer"
  end

  test "legacy worker path remains unused after VS-07A sales worker promotion" do
    refute File.exists?("lib/fastcheck/workers/paystack_webhook_worker.ex")
    assert File.exists?("lib/fastcheck/sales/payments/paystack_webhook_worker.ex")
  end
end
