defmodule FastCheck.Payments.Paystack.WebhookBoundaryTest do
  use ExUnit.Case, async: true

  @ingestion_path "lib/fastcheck/sales/payments/webhook_ingestion.ex"
  @worker_path "lib/fastcheck/sales/payments/paystack_webhook_worker.ex"
  @controller_path "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex"

  @ingestion_forbidden_tokens [
    "TransactionVerifier",
    "VerifyPaymentWorker",
    "PaymentVerification",
    "mark_verified_success",
    "mark_webhook_received",
    "mark_paid",
    "ReservationLedger",
    "IssueTickets",
    "TicketIssue",
    "DeliveryAttempt",
    "WhatsApp",
    "Attendee"
  ]

  @worker_forbidden_tokens [
    "TransactionVerifier",
    "PaymentVerification",
    "mark_verified_success",
    "mark_paid",
    "ReservationLedger",
    "IssueTickets",
    "TicketIssue",
    "DeliveryAttempt",
    "WhatsApp",
    "Attendee"
  ]

  test "vs-07a webhook modules exist in approved locations" do
    assert File.exists?(@controller_path)
    assert File.exists?(@worker_path)
    assert File.exists?(@ingestion_path)
    refute File.exists?("lib/fastcheck/workers/paystack_webhook_worker.ex")
  end

  test "ingestion orchestrator does not couple to verification ticketing or inventory" do
    source = File.read!(@ingestion_path)

    for token <- @ingestion_forbidden_tokens do
      refute String.contains?(source, token),
             "#{@ingestion_path} must not reference #{token} in VS-07A scope"
    end

    assert source =~ "Ecto.Multi"
    assert source =~ "Oban.insert"
    assert source =~ "validate_for_webhook"
  end

  test "webhook worker enqueues verify worker but does not call paystack directly" do
    source = File.read!(@worker_path)

    for token <- @worker_forbidden_tokens do
      refute String.contains?(source, token),
             "#{@worker_path} must not reference #{token} in VS-07B scope"
    end

    assert source =~ "VerifyPaymentWorker"
    assert source =~ "Ecto.Multi"
  end
end
