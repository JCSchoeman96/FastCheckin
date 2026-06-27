defmodule FastCheck.Sales.E2E.CheckoutExpiryRecoveryTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.CheckoutExpiry
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.CheckoutExpiryWorker

  @moduletag :e2e
  @moduletag :sales
  @moduletag :payments
  @moduletag :slow

  setup do
    paystack_cleanup = PaystackSupport.setup_paystack!()
    {event, offer} = E2E.setup_sales_event_offer!(sales_channel: "whatsapp")

    on_exit(fn ->
      FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "expired checkout releases hold once and duplicate expiry is idempotent", %{
    event: event,
    offer: offer
  } do
    %{order: order, session: session} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    E2E.set_session_expires_at!(session.id, minutes_ago: 5)
    assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 1

    assert :ok = perform_job(CheckoutExpiryWorker, %{"checkout_session_id" => session.id})
    assert {:ok, :skipped_terminal} = CheckoutExpiry.expire_session(session.id)

    assert E2E.reload_order!(order.id).status == "expired"
    assert E2E.reload_session!(session.id).status == "expired"
    assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 0
  end

  test "late verified payment after expiry moves to manual review and does not issue tickets", %{
    event: event,
    offer: offer
  } do
    %{order: order, session: session, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    E2E.set_session_expires_at!(session.id, minutes_ago: 5)
    assert {:ok, :expired} = CheckoutExpiry.expire_session(session.id)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :manual_review} = PaymentVerification.verify_attempt(attempt.id)
    assert E2E.reload_order!(order.id).status == "manual_review"
    assert E2E.reload_session!(session.id).status == "manual_review"
    assert E2E.sales_counts(order.id).ticket_issues == 0
  end

  test "payment verification wins safely when it completes before expiry", %{
    event: event,
    offer: offer
  } do
    %{order: order, session: session, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    E2E.set_session_expires_at!(session.id, minutes_ago: 5)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
    assert {:ok, :skipped_terminal} = CheckoutExpiry.expire_session(session.id)
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert E2E.reload_session!(session.id).status == "paid"
  end
end
