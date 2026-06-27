defmodule FastCheck.Sales.E2E.PaymentFailurePathsTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.SalesE2EFixtures, as: E2E

  @moduletag :e2e
  @moduletag :sales
  @moduletag :payments
  @moduletag :slow

  setup do
    paystack_cleanup = PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    {event, offer} = E2E.setup_sales_event_offer!(sales_channel: "whatsapp")

    on_exit(fn ->
      FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      PaystackSupport.flush_webhook_dedupe_keys!()
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "amount mismatch leaves order in manual review with no ticket or attendee", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents + 100,
        currency: attempt.currency
      )
    )

    assert {:ok, :mismatch} = PaymentVerification.verify_attempt(attempt.id)

    assert E2E.reload_order!(order.id).status == "manual_review"
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_amount_mismatch"

    assert E2E.sales_counts(order.id) == %{
             attendees: 0,
             ticket_issues: 0,
             issued_ticket_issues: 0
           }
  end

  test "currency and reference mismatches do not issue scanner-visible tickets", %{
    event: event,
    offer: offer
  } do
    for opts <- [
          [currency: "USD"],
          [reference: "wrong-reference-#{System.unique_integer([:positive])}"]
        ] do
      %{order: order, attempt: attempt} =
        E2E.start_initialized_checkout!(
          event,
          offer,
          source_channel: "whatsapp",
          idempotency_key: E2E.e2e_id("mismatch")
        )

      Application.put_env(
        :fastcheck,
        :paystack_request_fun,
        PaystackSupport.init_and_verify_request_fun(
          Keyword.merge([amount: attempt.amount_cents, currency: attempt.currency], opts)
        )
      )

      assert {:ok, outcome} = PaymentVerification.verify_attempt(attempt.id)
      assert outcome in [:mismatch, :manual_review]
      assert E2E.reload_order!(order.id).status == "manual_review"
      assert E2E.sales_counts(order.id).ticket_issues == 0
    end
  end

  test "provider failed or pending status does not issue tickets", %{event: event, offer: offer} do
    %{order: failed_order, attempt: failed_attempt} =
      E2E.start_initialized_checkout!(
        event,
        offer,
        source_channel: "whatsapp",
        idempotency_key: E2E.e2e_id("failed")
      )

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: failed_attempt.amount_cents,
        currency: failed_attempt.currency,
        provider_status: "failed"
      )
    )

    assert {:ok, :failed} = PaymentVerification.verify_attempt(failed_attempt.id)
    assert E2E.reload_order!(failed_order.id).status == "awaiting_payment"
    assert E2E.sales_counts(failed_order.id).ticket_issues == 0

    %{order: pending_order, attempt: pending_attempt} =
      E2E.start_initialized_checkout!(
        event,
        offer,
        source_channel: "whatsapp",
        idempotency_key: E2E.e2e_id("pending")
      )

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: pending_attempt.amount_cents,
        currency: pending_attempt.currency,
        provider_status: "pending"
      )
    )

    assert {:error, :retryable} = PaymentVerification.verify_attempt(pending_attempt.id)
    assert E2E.reload_order!(pending_order.id).status == "awaiting_payment"
    assert E2E.sales_counts(pending_order.id).ticket_issues == 0
  end

  test "unmatched webhook remains queryable without verification or issuance" do
    event =
      PaystackSupport.insert_payment_event!(%{
        provider_reference: E2E.e2e_id("missing-ref"),
        processing_status: "stored"
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})

    event = E2E.reload_payment_event!(event.id)
    assert event.processing_status == "unmatched"
    refute_enqueued(worker: VerifyPaymentWorker)
  end
end
