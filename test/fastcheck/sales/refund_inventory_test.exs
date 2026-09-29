defmodule FastCheck.Sales.RefundInventoryTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.RefundInventory
  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.Workers.RefundInventoryWorker

  test "held refund releases inventory once and records released_unconsumed" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-held-reserve-#{fixture.refund_id}"
             )

    assert {:ok, before} = ReservationLedger.get_availability(fixture.offer_id)
    assert before.available_quantity == 98
    assert before.reserved_quantity == fixture.quantity
    assert before.consumed_quantity == 0

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "completed", "manual review reason: #{refund.manual_review_reason}"
    assert refund.inventory_resolution_status == "released_unconsumed"

    assert {:ok, after_first} = ReservationLedger.get_availability(fixture.offer_id)
    assert after_first.available_quantity == 100
    assert after_first.reserved_quantity == 0
    assert after_first.consumed_quantity == 0

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.inventory_resolution_status == "released_unconsumed"
    assert {:ok, after_retry} = ReservationLedger.get_availability(fixture.offer_id)
    assert after_retry.available_quantity == 100
  end

  test "consumed refund completes as retained without changing inventory counters" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-consumed-reserve-#{fixture.refund_id}"
             )

    assert {:ok, _consumed} =
             ReservationLedger.consume(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               "refund-consumed-consume-#{fixture.refund_id}"
             )

    assert {:ok, before} = ReservationLedger.get_availability(fixture.offer_id)

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "completed"
    assert refund.inventory_resolution_status == "retained_consumed"

    assert {:ok, after_snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert after_snapshot.available_quantity == before.available_quantity
    assert after_snapshot.reserved_quantity == before.reserved_quantity
    assert after_snapshot.consumed_quantity == before.consumed_quantity
    assert after_snapshot.consumed_quantity == fixture.quantity
  end

  test "missing hold moves refund to inventory_manual_review" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"
    assert refund.inventory_resolution_status == nil
    assert is_binary(refund.manual_review_reason)

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100
    assert snapshot.consumed_quantity == 0
  end

  test "mismatched hold is not released" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               1,
               600,
               "refund-mismatched-reserve-#{fixture.refund_id}"
             )

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 99
    assert snapshot.reserved_quantity == 1
    assert snapshot.consumed_quantity == 0
  end

  test "ambiguous multi-line order is not released" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)
    insert_additional_order_line!(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-multiline-reserve-#{fixture.refund_id}"
             )

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"
    assert refund.manual_review_reason == "refund_order_line_ambiguous"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100 - fixture.quantity
    assert snapshot.reserved_quantity == fixture.quantity
    assert snapshot.consumed_quantity == 0
  end

  test "ambiguous payment-attempt authority is rejected before Redis release" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-multiple-payments-reserve-#{fixture.refund_id}"
             )

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, provider_status, provider_paid_at, verified_at,
         raw_verify_response, inserted_at, updated_at)
      VALUES ($1, 'paystack', $2, 'verified_success', $3, 'ZAR', 0, 'success',
              now(), now(), '{"status":"success"}'::jsonb, now(), now())
      """,
      [
        fixture.order_id,
        "refund-extra-attempt-#{fixture.refund_id}",
        fixture.total_amount_cents
      ]
    )

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"
    assert refund.manual_review_reason == "refund_payment_attempt_ambiguous"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100 - fixture.quantity
    assert snapshot.reserved_quantity == fixture.quantity
    assert snapshot.consumed_quantity == 0
  end

  test "expired held inventory moves to manual review without release" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-expired-hold-reserve-#{fixture.refund_id}"
             )

    assert {:ok, _updated_fields} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               ReservationLedger.hold_key(fixture.order_public_reference),
               "expires_at",
               Integer.to_string(System.system_time(:millisecond) - 1_000)
             ])

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"
    assert refund.manual_review_reason == "inventory_hold_expired"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100 - fixture.quantity
    assert snapshot.reserved_quantity == fixture.quantity
    assert snapshot.consumed_quantity == 0
  end

  test "released hold is accepted only when refund-specific release evidence exists" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-release-evidence-reserve-#{fixture.refund_id}"
             )

    assert {:ok, _released} =
             ReservationLedger.release(
               fixture.offer_id,
               fixture.order_public_reference,
               "refund:release:#{fixture.refund_id}",
               expected_quantity: fixture.quantity,
               require_unexpired?: true
             )

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "completed"
    assert refund.inventory_resolution_status == "released_unconsumed"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100
    assert snapshot.reserved_quantity == 0
  end

  test "release by another operation is ambiguous and requires manual review" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:ok, _hold} =
             ReservationLedger.reserve(
               fixture.offer_id,
               fixture.order_public_reference,
               fixture.quantity,
               600,
               "refund-foreign-release-reserve-#{fixture.refund_id}"
             )

    assert {:ok, _released} =
             ReservationLedger.release(
               fixture.offer_id,
               fixture.order_public_reference,
               "checkout:release:#{fixture.refund_id}"
             )

    assert {:ok, refund} = RefundInventory.resolve(fixture.refund_id)
    assert refund.status == "inventory_manual_review"

    assert {:ok, snapshot} = ReservationLedger.get_availability(fixture.offer_id)
    assert snapshot.available_quantity == 100
    assert snapshot.reserved_quantity == 0
  end

  test "final Redis retry failure moves refund to inventory_manual_review" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    SalesCheckoutFixtures.with_redis_stopped(fn ->
      job = %Oban.Job{args: %{"refund_id" => fixture.refund_id}, attempt: 5, max_attempts: 5}
      assert :ok = RefundInventoryWorker.perform(job)
    end)

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.id == ^fixture.refund_id,
               select: refund.status
           ) == "inventory_manual_review"
  end

  test "temporary Redis failure remains retryable without changing Refund state" do
    fixture = Fixtures.inventory_pending_refund_fixture()
    initialize_inventory(fixture)

    assert {:error, {:refund_inventory_retryable, :ledger_unavailable}} =
             SalesCheckoutFixtures.with_redis_stopped(fn ->
               RefundInventoryWorker.perform(%Oban.Job{
                 args: %{"refund_id" => fixture.refund_id},
                 attempt: 1,
                 max_attempts: 5
               })
             end)

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.id == ^fixture.refund_id,
               select: refund.status
           ) == "inventory_pending"
  end

  defp initialize_inventory(fixture) do
    on_exit(fn -> SalesCheckoutFixtures.flush_inventory_keys(fixture.offer_id) end)
    :ok = ReservationLedger.initialize_offer(fixture.offer_id, 100)
  end

  defp insert_additional_order_line!(fixture) do
    Repo.query!(
      """
      INSERT INTO sales_order_lines
        (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
         event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
         metadata, inserted_at, updated_at)
      VALUES ($1, $2, 2, 'general', 'Extra line', 'Event', 1, 100, 100, 'ZAR', '{}', now(), now())
      """,
      [fixture.order_id, fixture.offer_id]
    )
  end
end
