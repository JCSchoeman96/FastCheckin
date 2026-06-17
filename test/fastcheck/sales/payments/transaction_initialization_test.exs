defmodule FastCheck.Sales.Payments.TransactionInitializationTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Expr
  require Ash.Query
  import Ash.Expr

  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
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

  test "valid checkout session initializes paystack and creates payment attempt", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.success_request_fun())

    assert {:ok, result} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    refute result.idempotent?
    assert result.provider == :paystack
    assert result.authorization_url =~ "paystack"
    assert is_binary(result.provider_reference)

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: result.payment_attempt_id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "initialized"
    assert attempt.amount_cents == order.total_amount_cents
    assert attempt.currency == order.currency
    assert attempt.authorization_url =~ "paystack"

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session.id})
      |> Ash.read_one!(authorize?: false)

    assert session.status == "payment_link_sent"
  end

  test "missing buyer_email does not call paystack", %{offer: offer} do
    {_order, session} =
      TestSupport.checkout_ready_for_payment!(offer, %{buyer_email: nil})

    call_count = :counters.new(1, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      :counters.add(call_count, 1, 1)
      flunk("paystack should not be called")
    end)

    assert {:error, :missing_buyer_email} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(call_count, 1) == 0
  end

  test "cancelled order does not call paystack", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_orders SET status = 'cancelled', cancelled_at = now() WHERE id = $1",
      [order.id]
    )

    call_count = :counters.new(1, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      :counters.add(call_count, 1, 1)
      flunk("paystack should not be called")
    end)

    assert {:error, %{type: :invalid_order_state}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(call_count, 1) == 0
  end

  test "stale initializing attempt moves to manual review without paystack call", %{
    offer: offer
  } do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)
    idempotency_key = "paystack:init:#{order.id}:#{session.id}"

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, status,
         amount_cents, currency, verification_attempt_count, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', 'FC-STALE-1', $2, 'initializing', $3, 'ZAR', 0,
         now() - interval '5 minutes', now())
      """,
      [order.id, idempotency_key, order.total_amount_cents]
    )

    call_count = :counters.new(1, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      :counters.add(call_count, 1, 1)
      flunk("paystack should not be called for stale initializing")
    end)

    assert {:error, %{type: :stale_initialization}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(call_count, 1) == 0

    [%PaymentAttempt{status: "manual_review"} = reviewed] =
      PaymentAttempt
      |> Query.filter(expr(idempotency_key == ^idempotency_key))
      |> Ash.read!(authorize?: false)

    assert reviewed.manual_review_reason == "stale_initialization"
  end

  test "expired payment_link_sent session with initialized attempt does not replay paystack link",
       %{
         offer: offer
       } do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.success_request_fun())

    assert {:ok, first} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    Repo.query!(
      "UPDATE sales_checkout_sessions SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [session.id]
    )

    call_count = :counters.new(1, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      :counters.add(call_count, 1, 1)
      flunk("paystack should not be called for expired payment_link_sent replay")
    end)

    assert {:error, :checkout_session_expired} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(call_count, 1) == 0

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: first.payment_attempt_id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.status == "initialized"
    assert is_binary(attempt.authorization_url)
  end

  test "logs do not contain authorization_url or buyer_email", %{offer: offer} do
    {_order, session} =
      TestSupport.checkout_ready_for_payment!(offer, %{buyer_email: "secret-buyer@example.com"})

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.success_request_fun(
        authorization_url: "https://checkout.paystack.com/secret-url",
        access_code: "AC_SECRET"
      )
    )

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 TransactionInitialization.initialize_for_checkout_session(
                   session.id,
                   Fixtures.system_actor()
                 )
      end)

    refute log =~ "secret-url"
    refute log =~ "AC_SECRET"
    refute log =~ "secret-buyer@example.com"
    refute log =~ "sk_test"
  end
end
