defmodule FastCheck.Sales.Payments.PaymentFailureAndMismatchTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    offer = Fixtures.insert_offer!()

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      paystack_cleanup.()
    end)

    {:ok, offer: offer}
  end

  test "mismatch escalates order and checkout session to manual_review", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents + 1,
        currency: attempt.currency
      )
    )

    assert {:ok, :mismatch} = PaymentVerification.verify_attempt(attempt.id)

    order =
      Order |> Query.for_read(:get_by_id, %{id: order.id}) |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "manual_review"
    assert session.status == "manual_review"
    assert attempt.status == "verified_amount_mismatch"
    refute order.status == "paid_verified"
  end
end
