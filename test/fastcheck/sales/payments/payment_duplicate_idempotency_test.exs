defmodule FastCheck.Sales.Payments.PaymentDuplicateIdempotencyTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.Inventory.ReservationLedger
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

  test "duplicate verify after paid_verified does not re-call paystack", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    {flunk_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, flunk_fun)

    assert {:ok, :idempotent} = PaymentVerification.verify_attempt(attempt.id)
    assert :counters.get(counter, 1) == 0
  end

  test "second payment attempt on paid order is marked duplicate without inventory mutation", %{
    offer: offer
  } do
    %{order: order, attempt: first_attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: first_attempt.amount_cents,
        currency: first_attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(first_attempt.id)

    {:ok, availability_before} = ReservationLedger.get_availability(offer.id)

    second_attempt =
      TestSupport.insert_initialized_attempt!(order, %{
        provider_reference: "FC-DUP-2",
        idempotency_key: "paystack:init:#{order.id}:dup2"
      })

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: second_attempt.amount_cents,
        currency: second_attempt.currency,
        reference: second_attempt.provider_reference
      )
    )

    assert {:ok, :idempotent} = PaymentVerification.verify_attempt(second_attempt.id)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    second_attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: second_attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "paid_verified"
    assert second_attempt.status == "duplicate"
    assert second_attempt.failure_code == "payment_duplicate_suspicious"

    {:ok, availability_after} = ReservationLedger.get_availability(offer.id)
    assert availability_after.consumed_quantity == availability_before.consumed_quantity
    assert availability_after.available_quantity == availability_before.available_quantity
  end
end
