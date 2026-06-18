defmodule FastCheck.Sales.Payments.PaymentVerificationIdempotencyTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.StateTransition
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

  test "duplicate verify skips paystack after verified_success", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    request_fun =
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    {flunk_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, flunk_fun)

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "processing_started"
      })

    assert {:ok, :idempotent} =
             PaymentVerification.verify_attempt(attempt.id, payment_event_id: event.id)

    assert :counters.get(counter, 1) == 0

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "paid_verified"
    assert session.status == "paid"
    assert event.id && event.processing_status == "processing_started"

    updated_event =
      FastCheck.Sales.PaymentEvent
      |> Query.for_read(:get_by_id, %{id: event.id})
      |> Ash.read_one!(authorize?: false)

    assert updated_event.processing_status == "processed"
  end

  test "duplicate verify on expired checkout does not re-call paystack or mutate order", %{
    offer: offer
  } do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    session
    |> Ash.Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    transitions_before =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "PaymentAttempt",
        entity_id: to_string(attempt.id)
      })
      |> Ash.read!(authorize?: false)

    {flunk_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, flunk_fun)

    assert {:ok, :idempotent} = PaymentVerification.verify_attempt(attempt.id)
    assert :counters.get(counter, 1) == 0

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "awaiting_payment"
    assert session.status == "expired"

    transitions_after =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "PaymentAttempt",
        entity_id: to_string(attempt.id)
      })
      |> Ash.read!(authorize?: false)

    assert length(transitions_after) == length(transitions_before)
  end

  test "mark_verification_started is re-entrant after timeout retry", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.timeout_request_fun())

    assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "verification_started"

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
  end
end
