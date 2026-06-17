defmodule FastCheck.Sales.Payments.PaystackInitializationIdempotencyTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
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

  test "repeated initialization returns existing link without second paystack call", %{
    offer: offer
  } do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    {request_fun, counter} =
      TestSupport.counting_request_fun(TestSupport.success_request_fun())

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:ok, first} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    refute first.idempotent?

    assert {:ok, second} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert second.idempotent?
    assert second.payment_attempt_id == first.payment_attempt_id
    assert second.authorization_url == first.authorization_url
    assert :counters.get(counter, 1) == 1
  end

  test "concurrent duplicate initialization creates exactly one paystack provider call", %{
    offer: offer
  } do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    {request_fun, counter} =
      TestSupport.counting_request_fun(TestSupport.success_request_fun())

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    parent = self()

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(FastCheck.Repo, parent, self())

          TransactionInitialization.initialize_for_checkout_session(
            session.id,
            Fixtures.system_actor()
          )
        end)
      end

    results = Task.await_many(tasks, 30_000)

    assert Enum.all?(results, fn
             {:ok, %{status: :initialized}} -> true
             {:error, :payment_initialization_in_progress} -> true
             _ -> false
           end)

    successes =
      results
      |> Enum.filter(&match?({:ok, %{status: :initialized}}, &1))
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(successes) >= 1
    assert Enum.uniq(Enum.map(successes, & &1.payment_attempt_id)) |> length() == 1
    assert :counters.get(counter, 1) == 1
  end

  test "recent initializing attempt returns in progress without second paystack call", %{
    offer: offer
  } do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)
    idempotency_key = "paystack:init:#{order.id}:#{session.id}"

    FastCheck.Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, status,
         amount_cents, currency, verification_attempt_count, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', 'FC-INPROG-1', $2, 'initializing', $3, 'ZAR', 0, now(), now())
      """,
      [order.id, idempotency_key, order.total_amount_cents]
    )

    call_count = :counters.new(1, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      :counters.add(call_count, 1, 1)
      flunk("paystack should not be called")
    end)

    assert {:error, :payment_initialization_in_progress} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(call_count, 1) == 0
  end

  test "failed attempt does not block new active attempt at schema level", %{offer: offer} do
    {order, session} = TestSupport.checkout_ready_for_payment!(offer)
    idempotency_key = "paystack:init:#{order.id}:#{session.id}"

    FastCheck.Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, status,
         amount_cents, currency, verification_attempt_count, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', 'FC-FAILED-1', $2, 'failed', $3, 'ZAR', 0, now(), now())
      """,
      [order.id, idempotency_key, order.total_amount_cents]
    )

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

    assert attempt.status == "initialized"
  end
end
