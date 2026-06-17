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

  @forbidden_paths [
    "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex",
    "lib/fastcheck/workers/paystack_webhook_worker.ex",
    "lib/fastcheck/workers/verify_payment_worker.ex"
  ]

  test "vs-06c does not add paystack webhook controllers or workers" do
    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for initialization"
    end
  end

  test "initialization orchestrator does not couple to verification, ticketing, or inventory" do
    source = File.read!(@orchestrator_path)

    for token <- @forbidden_tokens do
      refute String.contains?(source, token),
             "#{@orchestrator_path} must not reference #{token} in VS-06C scope"
    end

    assert source =~ "FastCheck.Payments.Paystack.TransactionInitializer"
  end
end
