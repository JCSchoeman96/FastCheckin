defmodule FastCheck.Sales.Payments.TransactionInitializationTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Expr
  require Ash.Query
  import Ash.Expr

  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
  alias FastCheck.Sales.StateTransition
  alias FastCheck.Sales.TicketOffer
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
    refute Map.has_key?(result, :access_code)

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

    attempt_transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "PaymentAttempt",
        entity_id: to_string(attempt.id)
      })
      |> Ash.read!(authorize?: false)

    assert Enum.any?(attempt_transitions, &(&1.to_state == "initializing"))
    assert Enum.any?(attempt_transitions, &(&1.to_state == "initialized"))

    session_transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "CheckoutSession",
        entity_id: to_string(session.id)
      })
      |> Ash.read!(authorize?: false)

    assert Enum.any?(session_transitions, &(&1.to_state == "payment_link_sent"))
  end

  test "initialization uses order snapshot amount not current offer price", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    TicketOffer
    |> Ash.get!(offer.id, authorize?: false)
    |> Ash.Changeset.for_update(:update_offer, %{price_cents: 99_999},
      actor: Fixtures.admin_actor()
    )
    |> Ash.update!(authorize?: false)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.success_request_fun())

    assert {:ok, result} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    attempt =
      PaymentAttempt
      |> Query.for_read(:get_by_id, %{id: result.payment_attempt_id})
      |> Ash.read_one!(authorize?: false)

    assert attempt.amount_cents == order.total_amount_cents
    refute attempt.amount_cents == 99_999
  end

  test "invalid order statuses do not call paystack", %{offer: offer} do
    for status <- ["expired", "refunded", "ticket_issued", "manual_review"] do
      {order, session} = TestSupport.checkout_ready_for_payment!(offer)

      Repo.query!(
        "UPDATE sales_orders SET status = $1 WHERE id = $2",
        [status, order.id]
      )

      {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
      Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

      assert {:error, %{type: :invalid_order_state}} =
               TransactionInitialization.initialize_for_checkout_session(
                 session.id,
                 Fixtures.system_actor()
               )

      assert :counters.get(counter, 1) == 0
    end
  end

  test "expired hold_attached checkout session does not call paystack", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_checkout_sessions SET expires_at = now() - interval '1 minute' WHERE id = $1",
      [session.id]
    )

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, :checkout_session_expired} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "released checkout session does not call paystack", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_checkout_sessions SET status = 'released', released_at = now() WHERE id = $1",
      [session.id]
    )

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, %{type: :invalid_checkout_session_state}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "checkout session without redis hold does not call paystack", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_checkout_sessions SET redis_hold_key = NULL WHERE id = $1",
      [session.id]
    )

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, :hold_not_attached} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "hold quantity mismatch does not call paystack", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_checkout_sessions SET hold_quantity = 99 WHERE id = $1",
      [session.id]
    )

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, :hold_quantity_mismatch} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "order without lines does not call paystack", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!("DELETE FROM sales_order_lines WHERE sales_order_id = $1", [order.id])

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, :invalid_order_state} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "order total mismatch with lines does not call paystack", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Repo.query!(
      "UPDATE sales_orders SET total_amount_cents = 1 WHERE id = $1",
      [order.id]
    )

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, :invalid_order_amount} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end

  test "provider timeout marks attempt failed and leaves order awaiting payment", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.timeout_request_fun())

    assert {:error, %{type: :timeout, retryable?: true}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert_order_and_session_unchanged!(order.id, session.id)

    [attempt] =
      PaymentAttempt
      |> Query.filter(expr(sales_order_id == ^order.id))
      |> Ash.read!(authorize?: false)

    assert attempt.status == "failed"
    assert attempt.failure_code == "timeout"
  end

  test "provider 401 marks attempt failed without paid state", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.status_request_fun(401, ~s({"status": false, "message": "Unauthorized"}))
    )

    assert {:error, %{type: :unauthorized}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert_order_and_session_unchanged!(order.id, session.id)

    [attempt] =
      PaymentAttempt
      |> Query.filter(expr(sales_order_id == ^order.id))
      |> Ash.read!(authorize?: false)

    assert attempt.status == "failed"
  end

  test "provider 500 marks attempt failed without paid state", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.status_request_fun(500, ~s({"status": false, "message": "server error"}))
    )

    assert {:error, %{type: :provider_error}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert_order_and_session_unchanged!(order.id, session.id)

    [attempt] =
      PaymentAttempt
      |> Query.filter(expr(sales_order_id == ^order.id))
      |> Ash.read!(authorize?: false)

    assert attempt.status == "failed"
  end

  test "200 response missing authorization_url does not mark PaymentAttempt initialized", %{
    offer: offer
  } do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)

    {request_fun, counter} =
      TestSupport.counting_request_fun(TestSupport.malformed_success_request_fun())

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    log =
      capture_log(fn ->
        assert {:error, %{type: :invalid_provider_response}} =
                 TransactionInitialization.initialize_for_checkout_session(
                   session.id,
                   Fixtures.system_actor()
                 )
      end)

    assert :counters.get(counter, 1) == 1
    assert_order_and_session_unchanged!(order.id, session.id)

    [attempt] =
      PaymentAttempt
      |> Query.filter(expr(sales_order_id == ^order.id))
      |> Ash.read!(authorize?: false)

    assert attempt.status == "failed"
    assert attempt.failure_code == "invalid_provider_response"
    refute is_binary(attempt.authorization_url) and attempt.authorization_url != ""

    refute log =~ "authorization_url"
    refute log =~ "access_code"
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

  defp assert_order_and_session_unchanged!(order_id, session_id) do
    order =
      Order
      |> Query.for_read(:get_by_id, %{id: order_id})
      |> Ash.read_one!(authorize?: false)

    session =
      CheckoutSession
      |> Query.for_read(:get_by_id, %{id: session_id})
      |> Ash.read_one!(authorize?: false)

    assert order.status == "awaiting_payment"
    assert session.status == "hold_attached"
  end
end
