defmodule FastCheck.Sales.Inventory.RefundReconciliationTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheck.Sales.Inventory.DurableSnapshot
  alias FastCheck.Sales.Inventory.Reconciler
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures

  setup do
    fixture = Fixtures.inventory_pending_refund_fixture()
    on_exit(fn -> SalesCheckoutFixtures.flush_inventory_keys(fixture.offer_id) end)
    :ok = ReservationLedger.initialize_offer(fixture.offer_id, 100)
    {:ok, fixture: fixture}
  end

  test "inventory_pending refund remains sold and reports pending resolution", %{fixture: fixture} do
    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)

    assert snapshot.sold_count == fixture.quantity
    assert snapshot.safe_available == 100 - fixture.quantity
    refute snapshot.manual_review_required?
    assert Enum.any?(snapshot.anomalies, &(&1.code == :refund_inventory_resolution_pending))
  end

  test "retained_consumed remains sold", %{fixture: fixture} do
    set_refund_resolution!(fixture.refund_id, "retained_consumed")

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == fixture.quantity
    assert snapshot.safe_available == 100 - fixture.quantity
    refute snapshot.manual_review_required?
  end

  test "released_unconsumed is the only completed refund excluded from sold count", %{
    fixture: fixture
  } do
    set_refund_resolution!(fixture.refund_id, "released_unconsumed")

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == 0
    assert snapshot.safe_available == 100
    refute snapshot.manual_review_required?
  end

  test "released resolution on a multi-line order remains sold and requires review", %{
    fixture: fixture
  } do
    set_refund_resolution!(fixture.refund_id, "released_unconsumed")
    insert_additional_order_line!(fixture)

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == fixture.quantity + 1
    assert snapshot.safe_available == 100 - fixture.quantity - 1
    assert snapshot.manual_review_required?
    assert Enum.any?(snapshot.anomalies, &(&1.code == :refund_inventory_resolution_ambiguous))
  end

  test "released resolution with invalid payment authority stays sold and requires review", %{
    fixture: fixture
  } do
    set_refund_resolution!(fixture.refund_id, "released_unconsumed")

    Repo.query!("UPDATE sales_payment_attempts SET provider = 'stripe' WHERE id = $1", [
      fixture.payment_attempt_id
    ])

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == fixture.quantity
    assert snapshot.safe_available == 100 - fixture.quantity
    assert snapshot.manual_review_required?
    assert Enum.any?(snapshot.anomalies, &(&1.code == :refund_inventory_resolution_ambiguous))
  end

  test "inventory_manual_review stays sold and requires review", %{fixture: fixture} do
    Repo.query!(
      "UPDATE sales_refunds SET status = 'inventory_manual_review' WHERE id = $1",
      [fixture.refund_id]
    )

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == fixture.quantity
    assert snapshot.safe_available == 100 - fixture.quantity
    assert snapshot.manual_review_required?

    assert Enum.any?(snapshot.anomalies, &(&1.code == :refund_inventory_resolution_manual_review))
  end

  test "legacy refunded Order without Refund stays sold and cannot be repaired upward", %{
    fixture: fixture
  } do
    Repo.query!("DELETE FROM sales_refunds WHERE id = $1", [fixture.refund_id])

    assert {:ok, snapshot} = DurableSnapshot.fetch(fixture.offer_id)
    assert snapshot.sold_count == fixture.quantity
    assert snapshot.safe_available == 100 - fixture.quantity
    assert snapshot.manual_review_required?
    assert Enum.any?(snapshot.anomalies, &(&1.code == :legacy_refund_without_provider_evidence))

    assert {:manual_review_required, report} =
             Reconciler.reconcile_offer(fixture.offer_id, dry_run: false, allow_repair: true)

    assert report.expected_available == 100 - fixture.quantity
    refute report.repair_applied?
    assert {:ok, redis} = ReservationLedger.get_availability(fixture.offer_id)
    assert redis.available_quantity == 100
  end

  defp set_refund_resolution!(refund_id, resolution) do
    Repo.query!(
      """
      UPDATE sales_refunds
      SET status = 'completed', inventory_resolution_status = $2,
          completed_at = now(), updated_at = now()
      WHERE id = $1
      """,
      [refund_id, resolution]
    )
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
