defmodule FastCheck.Payments.Paystack.WebhookBoundaryTest do
  use ExUnit.Case, async: true

  @ingestion_path "lib/fastcheck/sales/payments/webhook_ingestion.ex"
  @worker_path "lib/fastcheck/sales/payments/paystack_webhook_worker.ex"
  @controller_path "lib/fastcheck_web/controllers/webhooks/paystack_controller.ex"

  @forbidden_tokens [
    "TransactionVerifier",
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

  test "vs-07a webhook modules exist in approved locations" do
    assert File.exists?(@controller_path)
    assert File.exists?(@worker_path)
    assert File.exists?(@ingestion_path)
    refute File.exists?("lib/fastcheck/workers/paystack_webhook_worker.ex")
  end

  test "ingestion orchestrator does not couple to verification ticketing or inventory" do
    source = File.read!(@ingestion_path)

    for token <- @forbidden_tokens do
      refute String.contains?(source, token),
             "#{@ingestion_path} must not reference #{token} in VS-07A scope"
    end

    assert source =~ "Ecto.Multi"
    assert source =~ "Oban.insert"
    assert source =~ "validate_for_webhook"
  end

  test "worker does not verify transactions or mutate paid state" do
    source = File.read!(@worker_path)

    for token <- @forbidden_tokens do
      refute String.contains?(source, token),
             "#{@worker_path} must not reference #{token} in VS-07A scope"
    end
  end
end
