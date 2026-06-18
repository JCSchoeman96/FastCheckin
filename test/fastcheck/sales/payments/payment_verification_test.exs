defmodule FastCheck.Sales.Payments.PaymentVerificationTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

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

  test "matching provider success verifies attempt and marks order and session paid", %{
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

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "verified_success"
    assert order.status == "paid_verified"
    assert session.status == "paid"
    refute Map.has_key?(attempt.raw_verify_response || %{}, "email")
    refute Map.has_key?(attempt.raw_verify_response || %{}, "authorization_url")
  end

  test "provider failed status does not mark order paid", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency,
        provider_status: "failed"
      )
    )

    assert {:ok, :failed} = PaymentVerification.verify_attempt(attempt.id)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "failed"
    assert order.status == "awaiting_payment"
  end

  test "provider pending status is retryable and does not mark order paid", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency,
        provider_status: "pending"
      )
    )

    assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "awaiting_payment"
    assert attempt.status == "verification_started"
  end

  test "amount mismatch moves order to manual_review and leaves unpaid", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents + 100,
        currency: attempt.currency
      )
    )

    assert {:ok, :mismatch} = PaymentVerification.verify_attempt(attempt.id)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "verified_amount_mismatch"
    assert order.status == "manual_review"
    assert order.manual_review_reason == "payment_amount_mismatch"
  end

  test "currency mismatch moves order to manual_review and leaves unpaid", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: "USD"
      )
    )

    assert {:ok, :mismatch} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "verified_currency_mismatch"
    assert order.status == "manual_review"
    assert order.manual_review_reason == "payment_currency_mismatch"
  end

  test "expired checkout with provider success applies late-payment recovery when inventory allows",
       %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    session
    |> Ash.Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "verified_success"
    assert order.status == "paid_verified"
    assert session.status == "paid"
  end

  test "provider timeout is retryable", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.timeout_request_fun())

    assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)
  end

  test "missing provider reference with success status does not mark paid", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency,
        omit_reference: true
      )
    )

    assert {:ok, :manual_review} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "manual_review"
    assert attempt.manual_review_reason == "payment_reference_mismatch"
    refute attempt.status == "verified_success"
    assert order.status == "manual_review"
    refute session.status == "paid"
  end

  test "blank provider reference with success status does not mark paid", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency,
        reference: "   "
      )
    )

    assert {:ok, :manual_review} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "manual_review"
    assert order.status == "manual_review"
  end

  test "non-retryable verify decode error marks attempt failed and leaves order unpaid", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_decode_error_request_fun()
    )

    assert {:ok, :failed} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "failed"
    assert attempt.failure_code == "verifier_decode_error"
    refute attempt.status == "verification_started"
    assert order.status == "awaiting_payment"
  end

  test "non-retryable verify HTTP 404 marks attempt failed and leaves order unpaid", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_http_error_request_fun(404)
    )

    assert {:ok, :failed} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "failed"
    assert attempt.failure_code == "verifier_not_found"
    assert order.status == "awaiting_payment"
  end

  test "non-retryable provider status false marks attempt failed", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_http_error_request_fun(200, ~s({"status":false,"message":"invalid"}))
    )

    assert {:ok, :failed} = PaymentVerification.verify_attempt(attempt.id)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: attempt.id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "failed"
    assert attempt.failure_code == "verifier_provider_error"
  end

  test "non-retryable verify error marks processing_started payment event failed", %{
    offer: offer
  } do
    alias Ash.Changeset
    alias FastCheck.Sales.PaymentEvent

    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    event =
      event
      |> Changeset.for_update(:mark_processing_started, %{}, actor: Fixtures.system_actor())
      |> Ash.update!(authorize?: false)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_http_error_request_fun(401)
    )

    assert {:ok, :failed} =
             PaymentVerification.verify_attempt(attempt.id, payment_event_id: event.id)

    event =
      PaymentEvent
      |> Query.for_read(:get_by_id, %{id: event.id})
      |> Ash.read_one!(authorize?: false)

    assert event.processing_status == "failed"
    assert is_binary(event.last_processing_error)
  end

  test "verification logs do not include secrets or buyer email", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    log =
      capture_log(fn ->
        assert {:ok, _} = PaymentVerification.verify_attempt(attempt.id)
      end)

    refute log =~ "buyer-secret@example.com"
    refute log =~ "sk_test_fake"
    refute log =~ "checkout.paystack.com/secret"
  end
end
