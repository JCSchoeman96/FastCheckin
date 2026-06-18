defmodule FastCheck.Payments.Paystack.BoundaryTest do
  use ExUnit.Case, async: true

  @paystack_modules [
    "lib/fastcheck/payments/paystack/config.ex",
    "lib/fastcheck/payments/paystack/client.ex",
    "lib/fastcheck/payments/paystack/transaction_initializer.ex",
    "lib/fastcheck/payments/paystack/transaction_verifier.ex",
    "lib/fastcheck/payments/paystack/webhook_verifier.ex",
    "lib/fastcheck/payments/paystack/webhook_event_parser.ex",
    "lib/fastcheck/payments/paystack/event_dedupe.ex"
  ]

  test "vs-06a paystack provider modules exist in provider boundary namespace" do
    for path <- @paystack_modules do
      assert File.exists?(path), "expected #{path}"
    end
  end

  test "paystack provider modules do not couple to ash sales resources" do
    forbidden_tokens = [
      "FastCheck.Sales.Order",
      "FastCheck.Sales.CheckoutSession",
      "FastCheck.Sales.PaymentAttempt",
      "FastCheck.Sales.PaymentEvent",
      "Ash."
    ]

    for file <- @paystack_modules do
      body = File.read!(file)

      for token <- forbidden_tokens do
        refute String.contains?(body, token), "#{file} must not reference #{token}"
      end
    end
  end

  test "vs-07a sales webhook ingress exists outside provider namespace" do
    assert File.exists?("lib/fastcheck_web/controllers/webhooks/paystack_controller.ex")
    assert File.exists?("lib/fastcheck/sales/payments/paystack_webhook_worker.ex")
    assert File.exists?("lib/fastcheck/sales/payments/webhook_ingestion.ex")
    refute File.exists?("lib/fastcheck/workers/paystack_webhook_worker.ex")
  end
end
