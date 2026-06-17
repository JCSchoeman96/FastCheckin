defmodule FastCheck.Payments.Paystack.BoundaryTest do
  use ExUnit.Case, async: true

  test "vs-06a does not add paystack controllers, routes, or workers" do
    refute File.exists?("lib/fastcheck_web/controllers/webhooks/paystack_controller.ex")
    refute File.exists?("lib/fastcheck/workers/paystack_webhook_worker.ex")
    refute File.exists?("lib/fastcheck/workers/verify_payment_worker.ex")
  end

  test "vs-06a paystack modules exist only in provider boundary namespace" do
    assert File.exists?("lib/fastcheck/payments/paystack/config.ex")
    assert File.exists?("lib/fastcheck/payments/paystack/client.ex")
    assert File.exists?("lib/fastcheck/payments/paystack/transaction_initializer.ex")
    assert File.exists?("lib/fastcheck/payments/paystack/transaction_verifier.ex")
    assert File.exists?("lib/fastcheck/payments/paystack/webhook_verifier.ex")
  end

  test "paystack modules do not couple to ash sales resources" do
    files = [
      "lib/fastcheck/payments/paystack/config.ex",
      "lib/fastcheck/payments/paystack/client.ex",
      "lib/fastcheck/payments/paystack/transaction_initializer.ex",
      "lib/fastcheck/payments/paystack/transaction_verifier.ex",
      "lib/fastcheck/payments/paystack/webhook_verifier.ex"
    ]

    forbidden_tokens = [
      "FastCheck.Sales.Order",
      "FastCheck.Sales.CheckoutSession",
      "FastCheck.Sales.PaymentAttempt",
      "FastCheck.Sales.PaymentEvent",
      "Ash."
    ]

    for file <- files do
      body = File.read!(file)

      for token <- forbidden_tokens do
        refute String.contains?(body, token), "#{file} must not reference #{token}"
      end
    end
  end
end
