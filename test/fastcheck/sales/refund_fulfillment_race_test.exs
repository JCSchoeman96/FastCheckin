defmodule FastCheck.Sales.RefundFulfillmentRaceTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: RefundFixtures
  alias FastCheck.Sales.AdminRefunds
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.RefundInventory
  alias FastCheck.SalesCheckoutFixtures, as: CheckoutFixtures
  alias FastCheck.Workers.PaidOrderFulfillmentWorker

  test "refund wins after fulfillment consumes but before its Order lock; consumed inventory stays sold" do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: RefundFixtures.dashboard_password()
    })

    fixture = create_committed_paid_order_fixture!()

    on_exit(fn ->
      cleanup_committed_fixture!(fixture)
    end)

    parent = self()

    lock_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [fixture.order_id])
            send(parent, {:refund_race_lock_held, self()})

            receive do
              :release_refund_race_lock -> :released
            after
              10_000 -> Repo.rollback(:refund_race_lock_timeout)
            end
          end)
        end)
      end)

    assert_receive {:refund_race_lock_held, lock_holder_pid}
    assert lock_holder_pid == lock_holder.pid

    fulfillment_task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          PaidOrderFulfillmentWorker.perform(%Oban.Job{
            args: %{"payment_attempt_id" => fixture.payment_attempt_id},
            attempt: 1,
            max_attempts: 5
          })
        end)
      end)

    refund_attrs = RefundFixtures.admin_attrs_for_order(fixture.order_id)
    refund_actor = RefundFixtures.admin_actor(event_id: fixture.event_id)

    refund_task =
      Task.async(fn ->
        receive do
          :start_refund ->
            Sandbox.unboxed_run(Repo, fn ->
              AdminRefunds.mark_order_refunded_manual(
                refund_actor,
                fixture.order_id,
                refund_attrs
              )
            end)
        end
      end)

    try do
      await_consumed_hold!(fixture)
      await_order_advisory_lock_waiters!(fixture.order_id, 1)

      send(refund_task.pid, :start_refund)
      await_order_advisory_lock_waiters!(fixture.order_id, 2)
      assert is_nil(Task.yield(fulfillment_task, 0))

      _ = Task.shutdown(fulfillment_task, :brutal_kill)
      refute Process.alive?(fulfillment_task.pid)
      send(lock_holder.pid, :release_refund_race_lock)
      assert {:ok, :released} = Task.await(lock_holder, 5_000)

      assert {:ok,
              %{
                order: %{status: "refunded"},
                refund: %{id: refund_id, status: "inventory_pending"}
              }} = Task.await(refund_task, 15_000)

      assert {:ok, before_resolution} = ReservationLedger.get_availability(fixture.offer_id)
      assert before_resolution.available_quantity == 9
      assert before_resolution.consumed_quantity == 1

      assert {:ok, resolved_refund} =
               Sandbox.unboxed_run(Repo, fn -> RefundInventory.resolve(refund_id) end)

      assert resolved_refund.status == "completed"
      assert resolved_refund.inventory_resolution_status == "retained_consumed"

      assert {:ok, after_resolution} = ReservationLedger.get_availability(fixture.offer_id)
      assert after_resolution.available_quantity == before_resolution.available_quantity
      assert after_resolution.reserved_quantity == before_resolution.reserved_quantity
      assert after_resolution.consumed_quantity == before_resolution.consumed_quantity

      assert Repo.one!(
               from order in "sales_orders",
                 where: order.id == ^fixture.order_id,
                 select: order.status
             ) == "refunded"

      refute_enqueued(
        worker: FastCheck.Workers.IssueTicketsWorker,
        args: %{"sales_order_id" => fixture.order_id}
      )
    after
      if Process.alive?(lock_holder.pid) do
        send(lock_holder.pid, :release_refund_race_lock)
      end

      stop_task_if_alive(fulfillment_task)
      if refund_task, do: stop_task_if_alive(refund_task)
      stop_task_if_alive(lock_holder)
    end
  end

  defp create_committed_paid_order_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      event = FastCheck.Fixtures.create_event()

      offer =
        CheckoutFixtures.insert_offer!(
          event_id: event.id,
          configured_quantity_available: 10,
          price_cents: 12_500
        )

      public_reference = "FC-REFUND-RACE-#{System.unique_integer([:positive])}"

      {:ok, {order_id, line_id, session_id, payment_attempt_id}} =
        Repo.transaction(fn ->
          %{rows: [[order_id]]} =
            Repo.query!(
              """
              INSERT INTO sales_orders
                (public_reference, event_id, buyer_name, source_channel, status,
                 total_amount_cents, currency, lock_version, inserted_at, updated_at)
              VALUES ($1, $2, 'Race Buyer', 'test', 'paid_verified', 12500, 'ZAR', 1, now(), now())
              RETURNING id
              """,
              [public_reference, event.id]
            )

          %{rows: [[line_id]]} =
            Repo.query!(
              """
              INSERT INTO sales_order_lines
                (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
                 event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
                 metadata, inserted_at, updated_at)
              VALUES ($1, $2, 1, 'general', 'Refund race offer', 'Refund race event', 1,
                      12500, 12500, 'ZAR', '{}', now(), now())
              RETURNING id
              """,
              [order_id, offer.id]
            )

          %{rows: [[session_id]]} =
            Repo.query!(
              """
              INSERT INTO sales_checkout_sessions
                (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
              VALUES ($1, 'paid', 1, '{}', 1, now(), now())
              RETURNING id
              """,
              [order_id]
            )

          %{rows: [[payment_attempt_id]]} =
            Repo.query!(
              """
              INSERT INTO sales_payment_attempts
                (sales_order_id, provider, provider_reference, status, amount_cents, currency,
                 verification_attempt_count, provider_status, provider_paid_at, verified_at,
                 inserted_at, updated_at)
              VALUES ($1, 'paystack', $2, 'verified_success', 12500, 'ZAR', 1,
                      'success', now(), now(), now(), now())
              RETURNING id
              """,
              [order_id, "race-pay-#{System.unique_integer([:positive])}"]
            )

          {order_id, line_id, session_id, payment_attempt_id}
        end)

      assert {:ok, _hold} =
               ReservationLedger.reserve(
                 offer.id,
                 public_reference,
                 1,
                 600,
                 "refund-race-reserve-#{payment_attempt_id}"
               )

      %{
        event_id: event.id,
        offer_id: offer.id,
        order_id: order_id,
        line_id: line_id,
        session_id: session_id,
        payment_attempt_id: payment_attempt_id,
        public_reference: public_reference
      }
    end)
  end

  defp await_consumed_hold!(fixture, attempts \\ 100)

  defp await_consumed_hold!(fixture, attempts) when attempts > 0 do
    case ReservationLedger.get_hold_detail(fixture.offer_id, fixture.public_reference) do
      {:ok, %{status: :consumed}} ->
        :ok

      _ ->
        Process.sleep(20)
        await_consumed_hold!(fixture, attempts - 1)
    end
  end

  defp await_consumed_hold!(_fixture, _attempts),
    do: raise("fulfillment did not consume the hold before waiting for the Order lock")

  defp await_order_advisory_lock_waiters!(order_id, expected_count) do
    Sandbox.unboxed_run(Repo, fn ->
      deadline = System.monotonic_time(:millisecond) + 5_000
      do_await_order_lock_waiters!(order_id, expected_count, deadline)
    end)
  end

  defp do_await_order_lock_waiters!(order_id, expected_count, deadline) do
    %{rows: [[waiter_count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_locks
        WHERE locktype = 'advisory'
          AND granted = false
          AND classid = 0::oid
          AND objid::bigint = $1::bigint
          AND objsubid = 1
        """,
        [order_id]
      )

    cond do
      waiter_count >= expected_count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "expected #{expected_count} Order lock waiters; saw #{waiter_count}"

      true ->
        Process.sleep(10)
        do_await_order_lock_waiters!(order_id, expected_count, deadline)
    end
  end

  defp stop_task_if_alive(%Task{pid: pid} = task) do
    if Process.alive?(pid) do
      case Task.yield(task, 5_000) do
        nil -> Task.shutdown(task, :brutal_kill)
        _result -> :ok
      end
    end
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      refund_id =
        Repo.one(
          from refund in "sales_refunds",
            where: refund.sales_order_id == ^fixture.order_id,
            select: refund.id
        )

      redis_keys = [
        "sales:offer:#{fixture.offer_id}:inventory",
        "sales:offer:#{fixture.offer_id}:holds",
        "sales:inventory:events:#{fixture.offer_id}",
        ReservationLedger.hold_key(fixture.public_reference),
        "sales:order:#{fixture.public_reference}:lock",
        "sales:inventory:dedupe:reserve:refund-race-reserve-#{fixture.payment_attempt_id}",
        "sales:inventory:dedupe:consume:paid_order_fulfillment:consume:#{fixture.payment_attempt_id}",
        "sales:inventory:dedupe:release:refund:release:#{refund_id}"
      ]

      _ = Redix.command(FastCheck.Redix, ["DEL" | Enum.reject(redis_keys, &is_nil/1)])

      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!(
                   "DELETE FROM oban_jobs WHERE worker = $1 AND args->>'refund_id' = $2",
                   ["FastCheck.Workers.RefundInventoryWorker", to_string(refund_id)]
                 )

                 Repo.query!(
                   "DELETE FROM sales_state_transitions WHERE (entity_type = 'Order' AND entity_id = $1::bigint::text) OR (entity_type = 'PaymentAttempt' AND entity_id = $2::bigint::text) OR (entity_type = 'Refund' AND entity_id IN (SELECT id::text FROM sales_refunds WHERE sales_order_id = $1))",
                   [fixture.order_id, fixture.payment_attempt_id]
                 )

                 Repo.query!("DELETE FROM sales_refunds WHERE sales_order_id = $1", [
                   fixture.order_id
                 ])

                 Repo.query!("DELETE FROM sales_payment_attempts WHERE sales_order_id = $1", [
                   fixture.order_id
                 ])

                 Repo.query!("DELETE FROM sales_checkout_sessions WHERE sales_order_id = $1", [
                   fixture.order_id
                 ])

                 Repo.query!("DELETE FROM sales_order_lines WHERE sales_order_id = $1", [
                   fixture.order_id
                 ])

                 Repo.query!("DELETE FROM sales_orders WHERE id = $1", [fixture.order_id])
                 Repo.query!("DELETE FROM sales_ticket_offers WHERE id = $1", [fixture.offer_id])
                 Repo.query!("DELETE FROM events WHERE id = $1", [fixture.event_id])
                 :cleaned
               end)
    end)
  end
end
