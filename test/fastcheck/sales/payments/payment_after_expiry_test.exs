defmodule FastCheck.Sales.Payments.PaymentAfterExpiryTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.Workers.PaidOrderFulfillmentWorker

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    offer = Fixtures.insert_offer!()

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      paystack_cleanup.()
      Application.delete_env(:fastcheck, :late_payment_recovery_consume_fun)
      Application.delete_env(:fastcheck, :late_payment_recovery_mark_paid_fun)
    end)

    {:ok, offer: offer}
  end

  test "late payment with unavailable inventory moves to manual_review", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    assert {:ok, _released} =
             ReservationLedger.release(
               offer.id,
               order.public_reference,
               "test:release:#{attempt.id}"
             )

    session
    |> Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    Fixtures.flush_inventory_keys(offer.id)
    :ok = ReservationLedger.initialize_offer(offer.id, 0)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :manual_review} = PaymentVerification.verify_attempt(attempt.id)

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
    assert order.status == "manual_review"
    assert session.status == "manual_review"
    assert order.manual_review_reason == "late_payment_inventory_unavailable"
  end

  test "late payment lock contention durably hands off retryable fulfillment", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    session
    |> Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    Application.put_env(
      :fastcheck,
      :late_payment_recovery_consume_fun,
      fn _ctx -> {:error, :lock_timeout, %{offer_id: offer.id}} end
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )

    assert reload_attempt!(attempt.id).status == "verified_success"
    assert reload_order!(order.id).status == "paid_verified"
    assert reload_session!(session.id).status == "paid"

    assert {:ok, %{ledger_state: :healthy, reserved_quantity: 1, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)

    Application.delete_env(:fastcheck, :late_payment_recovery_consume_fun)

    assert :ok =
             perform_job(PaidOrderFulfillmentWorker, %{"payment_attempt_id" => attempt.id})

    assert reload_order!(order.id).status == "fulfillment_queued"

    assert {:ok, %{ledger_state: :healthy, reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "late payment reserve failure remains retryable and a later verification completes", %{
    offer: offer
  } do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    session
    |> Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:error, :retryable} =
             Fixtures.with_redis_stopped(fn -> PaymentVerification.verify_attempt(attempt.id) end)

    assert reload_attempt!(attempt.id).status == "verification_started"
    assert reload_order!(order.id).status == "awaiting_payment"
    assert reload_session!(session.id).status == "expired"
    refute_enqueued(worker: PaidOrderFulfillmentWorker)

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
    assert reload_attempt!(attempt.id).status == "verified_success"
    assert reload_order!(order.id).status == "paid_verified"
    assert reload_session!(session.id).status == "paid"

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )
  end

  test "late payment release failure rolls back and can retry", %{offer: offer} do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    session
    |> Changeset.for_update(:expire_session, %{}, actor: Fixtures.system_actor())
    |> Ash.update!(authorize?: false)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    Application.put_env(:fastcheck, :late_payment_recovery_mark_paid_fun, fn ->
      Fixtures.stop_redis_connection!()
      {:error, :forced_db_failure}
    end)

    try do
      assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)
    after
      Fixtures.start_redis_connection!()
    end

    assert reload_attempt!(attempt.id).status == "verification_started"
    assert reload_order!(order.id).status == "awaiting_payment"
    assert reload_session!(session.id).status == "expired"
    refute_enqueued(worker: PaidOrderFulfillmentWorker)

    assert {:ok, %{available_quantity: 99, reserved_quantity: 1, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)

    Application.delete_env(:fastcheck, :late_payment_recovery_mark_paid_fun)

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
    assert reload_attempt!(attempt.id).status == "verified_success"
    assert reload_order!(order.id).status == "paid_verified"
    assert reload_session!(session.id).status == "paid"

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )
  end

  defp reload_attempt!(id) do
    PaymentAttempt
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_order!(id) do
    Order
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp reload_session!(id) do
    CheckoutSession
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end
end
