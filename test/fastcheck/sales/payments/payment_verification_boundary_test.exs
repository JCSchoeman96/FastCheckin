defmodule FastCheck.Sales.Payments.PaymentVerificationBoundaryTest do
  use ExUnit.Case, async: true

  @orchestrator_path "lib/fastcheck/sales/payments/payment_verification.ex"
  @verify_worker_path "lib/fastcheck/sales/payments/verify_payment_worker.ex"
  @webhook_worker_path "lib/fastcheck/sales/payments/paystack_webhook_worker.ex"

  @forbidden_tokens [
    "TicketIssue",
    "DeliveryAttempt",
    "IssueTickets",
    "FastCheck.Tickets",
    "Attendee",
    "WhatsApp",
    "ReservationLedger",
    "Redix",
    "sales:offer:",
    "queue_fulfillment"
  ]

  test "verification modules live under sales payments namespace" do
    assert File.exists?(@orchestrator_path)
    assert File.exists?(@verify_worker_path)
    refute File.exists?("lib/fastcheck/workers/verify_payment_worker.ex")
  end

  test "orchestrator and workers do not couple to ticketing inventory or scanner" do
    for path <- [@orchestrator_path, @verify_worker_path, @webhook_worker_path] do
      source = File.read!(path)

      for token <- @forbidden_tokens do
        refute String.contains?(source, token),
               "#{path} must not reference #{token} in VS-07B scope"
      end
    end

    assert String.contains?(File.read!(@orchestrator_path), "TransactionVerifier")
    assert String.contains?(File.read!(@webhook_worker_path), "Ecto.Multi")
  end
end
