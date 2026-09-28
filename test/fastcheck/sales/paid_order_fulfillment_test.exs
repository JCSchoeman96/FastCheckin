defmodule FastCheck.Sales.PaidOrderFulfillmentTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias FastCheck.Redis.Namespace
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.LatePaymentRecovery
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.StateTransition
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.Workers.IssueTicketsWorker
  alias FastCheck.Workers.PaidOrderFulfillmentWorker

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      paystack_cleanup.()
    end)

    {:ok, offer: offer}
  end

  test "verified payment consumes its hold before queueing the issuer", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert :ok = perform_fulfillment(attempt.id)

    assert_order_status(order.id, "fulfillment_queued")
    assert %DateTime{} = reload_order!(order.id).fulfillment_queued_at

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    assert {:ok,
            %{
              offer_id: offer_id,
              order_public_reference: reference,
              quantity: 1,
              status: :consumed
            }} =
             ReservationLedger.get_hold_detail(offer.id, order.public_reference)

    assert offer_id == offer.id
    assert reference == order.public_reference

    assert_enqueued(
      worker: IssueTicketsWorker,
      args: %{
        "sales_order_id" => order.id,
        "idempotency_key" => "paid-order-fulfillment:issue:#{order.id}"
      }
    )

    assert ticket_issue_count(order.id) == 0
  end

  test "duplicate fulfillment workers consume and transition once", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert :ok = perform_fulfillment(attempt.id)
    assert :ok = perform_fulfillment(attempt.id)

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    assert order_transition_count(order.id, "fulfillment_queued") == 1

    assert [job] =
             all_enqueued(
               worker: IssueTicketsWorker,
               args: %{"sales_order_id" => order.id}
             )

    assert job.args["idempotency_key"] == "paid-order-fulfillment:issue:#{order.id}"
  end

  test "consume uses the deterministic payment attempt key", %{offer: offer} do
    %{attempt: attempt} = paid_checkout!(offer)

    assert :ok = perform_fulfillment(attempt.id)

    key =
      Namespace.key("sales:inventory:dedupe:consume:paid_order_fulfillment:consume:#{attempt.id}")

    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["EXISTS", key])
  end

  test "an exact hold consumed by late payment recovery continues without consuming twice", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    late_ctx =
      LatePaymentRecovery.build_ctx(
        attempt.id,
        offer.id,
        order.public_reference,
        1
      )

    assert {:ok, %{status: :consumed}} =
             ReservationLedger.consume(
               offer.id,
               order.public_reference,
               1,
               late_ctx.consume_key
             )

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "fulfillment_queued")

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "a conflicting already-consumed hold fails closed", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)
    late_ctx = LatePaymentRecovery.build_ctx(attempt.id, offer.id, order.public_reference, 1)

    assert {:ok, _} =
             ReservationLedger.consume(offer.id, order.public_reference, 1, late_ctx.consume_key)

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               ReservationLedger.hold_key(order.public_reference),
               "offer_id",
               Integer.to_string(offer.id + 1)
             ])

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")
    assert reload_order!(order.id).manual_review_reason == "paid_order_fulfillment_hold_mismatch"

    assert {:ok, %{ledger_state: :reconciliation_required}} =
             ReservationLedger.get_availability(offer.id)

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "a consumed hold with malformed quantity fails closed", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:ok, _} =
             ReservationLedger.consume(
               offer.id,
               order.public_reference,
               1,
               "paid_order_fulfillment:consume:#{attempt.id}"
             )

    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               ReservationLedger.hold_key(order.public_reference),
               "quantity",
               "1junk"
             ])

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")

    assert reload_order!(order.id).manual_review_reason ==
             "paid_order_fulfillment_quantity_mismatch"

    assert {:ok,
            %{ledger_state: :reconciliation_required, reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "released inventory never queues the issuer", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:ok, _} =
             ReservationLedger.release(offer.id, order.public_reference, "release-#{attempt.id}")

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")
    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "expired inventory never queues the issuer", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               ReservationLedger.hold_key(order.public_reference),
               "status",
               "expired"
             ])

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")
    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "reconciliation-required inventory does not queue tickets", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)
    assert :ok = ReservationLedger.mark_offer_health(offer.id, :reconciliation_required, "test")

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")
    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "a consumed idempotent hold still fails closed when the ledger needs reconciliation", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:ok, _} =
             ReservationLedger.consume(
               offer.id,
               order.public_reference,
               1,
               "paid_order_fulfillment:consume:#{attempt.id}"
             )

    assert :ok = ReservationLedger.mark_offer_health(offer.id, :reconciliation_required, "test")

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "manual_review")

    assert reload_order!(order.id).manual_review_reason ==
             "paid_order_fulfillment_inventory_reconciliation_required"

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "a temporary Redis failure stays retryable", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:error, :retryable} =
             Fixtures.with_redis_stopped(fn ->
               PaidOrderFulfillmentWorker.perform(fulfillment_job(attempt.id))
             end)

    assert_order_status(order.id, "paid_verified")

    assert {:ok, %{reserved_quantity: 1, consumed_quantity: 0}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "the final retry opens manual review after a temporary Redis failure", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert :ok =
             Fixtures.with_redis_stopped(fn ->
               PaidOrderFulfillmentWorker.perform(
                 fulfillment_job(attempt.id, attempt: 5, max_attempts: 5)
               )
             end)

    assert_order_status(order.id, "manual_review")

    assert reload_order!(order.id).manual_review_reason ==
             "paid_order_fulfillment_retry_exhausted"

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "retry after process loss following consume continues from the exact consumed hold", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = paid_checkout!(offer)

    assert {:ok, _} =
             ReservationLedger.consume(
               offer.id,
               order.public_reference,
               1,
               consume_key(attempt.id)
             )

    assert_order_status(order.id, "paid_verified")
    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "fulfillment_queued")

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)
  end

  test "a database transition failure after consume keeps inventory consumed and can retry", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = paid_checkout!(offer)
    constraint = "p0b_test_block_fulfillment_#{order.id}"

    Repo.query!("ALTER TABLE sales_orders ADD CONSTRAINT #{constraint} CHECK (false) NOT VALID")

    assert {:error, :retryable} = PaidOrderFulfillmentWorker.perform(fulfillment_job(attempt.id))
    assert_order_status(order.id, "paid_verified")

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})

    Repo.query!("ALTER TABLE sales_orders DROP CONSTRAINT #{constraint}")

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "fulfillment_queued")
  end

  test "issuer insertion failure rolls back the fulfillment transition", %{offer: offer} do
    %{order: order, attempt: attempt} = paid_checkout!(offer)
    constraint = "p0b_test_block_issuer_#{order.id}"

    Repo.query!("ALTER TABLE oban_jobs ADD CONSTRAINT #{constraint} CHECK (false) NOT VALID")

    assert {:error, :retryable} = PaidOrderFulfillmentWorker.perform(fulfillment_job(attempt.id))
    assert_order_status(order.id, "paid_verified")
    assert reload_order!(order.id).fulfillment_queued_at == nil

    assert {:ok, %{reserved_quantity: 0, consumed_quantity: 1}} =
             ReservationLedger.get_availability(offer.id)

    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})

    Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT #{constraint}")

    assert :ok = perform_fulfillment(attempt.id)
    assert_order_status(order.id, "fulfillment_queued")
    assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  test "worker refuses an attempt that is not verified", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    assert {:discard, :payment_not_verified} =
             PaidOrderFulfillmentWorker.perform(fulfillment_job(attempt.id))

    assert_order_status(order.id, "awaiting_payment")
    refute_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
  end

  defp paid_checkout!(offer) do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)
    %{order: order, attempt: attempt}
  end

  defp perform_fulfillment(attempt_id) do
    perform_job(PaidOrderFulfillmentWorker, %{"payment_attempt_id" => attempt_id})
  end

  defp fulfillment_job(attempt_id, opts \\ []) do
    %Oban.Job{
      args: %{"payment_attempt_id" => attempt_id},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 5)
    }
  end

  defp consume_key(attempt_id),
    do: "paid_order_fulfillment:consume:#{attempt_id}"

  defp reload_order!(id) do
    Order
    |> Ash.Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp assert_order_status(order_id, status), do: assert(reload_order!(order_id).status == status)

  defp order_transition_count(order_id, status) do
    entity_id = Integer.to_string(order_id)

    Repo.one(
      from transition in StateTransition,
        where:
          transition.entity_type == "Order" and transition.entity_id == ^entity_id and
            transition.to_state == ^status,
        select: count(transition.id)
    )
  end

  defp ticket_issue_count(order_id) do
    Repo.one(
      from issue in "sales_ticket_issues",
        where: issue.sales_order_id == ^order_id,
        select: count(issue.id)
    )
  end
end
