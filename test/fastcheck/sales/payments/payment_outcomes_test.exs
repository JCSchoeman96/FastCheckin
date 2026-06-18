defmodule FastCheck.Sales.Payments.PaymentOutcomesTest do
  use ExUnit.Case, async: true

  alias FastCheck.Sales.Payments.PaymentFailureReason
  alias FastCheck.Sales.Payments.PaymentOutcomes

  describe "classify_provider_result/4" do
    test "success with active checkout classifies verified_active_checkout" do
      result = %{
        provider_status: "success",
        amount: 5000,
        currency: "ZAR",
        provider_reference: "ref-1",
        safe_data: %{},
        paid_at: "2026-06-17T08:00:00Z"
      }

      attempt = %{
        status: "verification_started",
        amount_cents: 5000,
        currency: "ZAR",
        provider_reference: "ref-1"
      }

      order =
        struct(FastCheck.Sales.Order, %{
          status: "awaiting_payment",
          total_amount_cents: 5000,
          currency: "ZAR"
        })

      session = struct(FastCheck.Sales.CheckoutSession, %{status: "payment_link_sent"})

      assert {:ok, :verified_active_checkout, attrs} =
               PaymentOutcomes.classify_provider_result(result, attempt, order, session)

      refute Map.has_key?(attrs, :reason_code)
    end

    test "amount mismatch classifies with stable reason code" do
      result = %{
        provider_status: "success",
        amount: 5100,
        currency: "ZAR",
        provider_reference: "ref-1",
        safe_data: %{}
      }

      attempt = %{
        status: "verification_started",
        amount_cents: 5000,
        currency: "ZAR",
        provider_reference: "ref-1"
      }

      order =
        struct(FastCheck.Sales.Order, %{
          status: "awaiting_payment",
          total_amount_cents: 5000,
          currency: "ZAR"
        })

      session = struct(FastCheck.Sales.CheckoutSession, %{status: "payment_link_sent"})

      assert {:ok, :amount_mismatch, attrs} =
               PaymentOutcomes.classify_provider_result(result, attempt, order, session)

      assert attrs.reason_code == PaymentFailureReason.payment_amount_mismatch()
    end

    test "expired session with success requires late payment recovery" do
      result = %{
        provider_status: "success",
        amount: 5000,
        currency: "ZAR",
        provider_reference: "ref-1",
        safe_data: %{},
        paid_at: "2026-06-17T08:00:00Z"
      }

      attempt = %{
        status: "verification_started",
        amount_cents: 5000,
        currency: "ZAR",
        provider_reference: "ref-1"
      }

      order =
        struct(FastCheck.Sales.Order, %{
          status: "awaiting_payment",
          total_amount_cents: 5000,
          currency: "ZAR"
        })

      session = struct(FastCheck.Sales.CheckoutSession, %{status: "expired"})

      assert {:ok, :late_payment_recovery_required, _attrs} =
               PaymentOutcomes.classify_provider_result(result, attempt, order, session)
    end

    test "provider pending is retryable" do
      result = %{
        provider_status: "pending",
        amount: 5000,
        currency: "ZAR",
        provider_reference: "ref-1",
        safe_data: %{}
      }

      attempt = %{
        status: "verification_started",
        amount_cents: 5000,
        currency: "ZAR",
        provider_reference: "ref-1"
      }

      order =
        struct(FastCheck.Sales.Order, %{
          status: "awaiting_payment",
          total_amount_cents: 5000,
          currency: "ZAR"
        })

      session = struct(FastCheck.Sales.CheckoutSession, %{status: "payment_link_sent"})

      assert {:error, :retryable} =
               PaymentOutcomes.classify_provider_result(result, attempt, order, session)
    end
  end
end
