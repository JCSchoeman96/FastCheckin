defmodule FastCheck.Sales.Inventory.ReconcilerTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.Reconciler
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "dry-run reconcile reports missing inventory hash with planned rebuild", %{offer: offer} do
    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{offer.id}:inventory"])

    assert {:ok, report} = Reconciler.reconcile_offer(offer.id, dry_run: true)
    assert report.dry_run?
    assert report.health_before == :reconciliation_required
    assert report.redis_available_before == nil
    assert report.expected_available == 10
    refute report.repair_applied?
    assert Enum.any?(report.planned_actions, &(&1.action == :rebuild_inventory))
    assert Enum.any?(report.anomalies, &(&1.code == :missing_redis_inventory))
  end

  test "repair mode rebuilds missing inventory hash when durable state is safe", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 2,
        idempotency_key: "recon-missing-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{offer.id}:inventory"])

    assert {:ok, report} =
             Reconciler.reconcile_offer(offer.id, dry_run: false, allow_repair: true)

    assert report.repair_applied?
    assert report.health_after == :healthy
    assert report.redis_available_after == 8

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.available_quantity == 8
    assert snapshot.reserved_quantity == 2
  end

  test "orphan redis hold returns manual_review_required", %{offer: offer} do
    orphan_ref = "ORD-ORPHAN-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ReservationLedger.reserve(offer.id, orphan_ref, 1, 1, "idem-orphan-#{orphan_ref}")

    assert {:manual_review_required, report} = Reconciler.reconcile_offer(offer.id, dry_run: true)
    assert report.manual_review_required?
    assert report.orphan_hold_count == 1
    assert Enum.any?(report.anomalies, &(&1.code == :orphan_redis_holds))
    refute report.repair_applied?
  end

  test "dry-run reconcile reports drift without mutating redis", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 2,
        idempotency_key: "recon-dry-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:ok, before} = ReservationLedger.get_availability(offer.id)
    assert before.available_quantity == 8

    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               "sales:offer:#{offer.id}:inventory",
               "available_quantity",
               "10"
             ])

    assert {:ok, report} = Reconciler.reconcile_offer(offer.id, dry_run: true)
    assert report.dry_run?
    assert report.expected_available == 8
    assert report.redis_available_before == 10
    refute report.repair_applied?

    assert {:ok, after_snapshot} = ReservationLedger.get_availability(offer.id)
    assert after_snapshot.available_quantity == 10

    assert order.status == "awaiting_payment"
  end

  test "reconcile repairs redis downward when allow_repair is true", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 2,
        idempotency_key: "recon-repair-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               "sales:offer:#{offer.id}:inventory",
               "available_quantity",
               "10"
             ])

    assert {:ok, report} =
             Reconciler.reconcile_offer(offer.id, dry_run: false, allow_repair: true)

    assert report.repair_applied?
    assert report.redis_available_after == 8

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.available_quantity == 8
    assert snapshot.ledger_state == :healthy
  end

  test "manual_review_required when safe available is negative", %{offer: offer} do
    order_id = insert_paid_order!(offer.id, quantity: 12)

    refute order_id == nil

    assert {:manual_review_required, report} = Reconciler.reconcile_offer(offer.id, dry_run: true)
    assert report.manual_review_required?
  end

  test "duplicate reconcile execution is idempotent", %{offer: offer} do
    assert {:ok, _} =
             Redix.command(FastCheck.Redix, [
               "HSET",
               "sales:offer:#{offer.id}:inventory",
               "available_quantity",
               "12"
             ])

    assert {:ok, first} = Reconciler.reconcile_offer(offer.id, dry_run: false, allow_repair: true)

    assert {:ok, second} =
             Reconciler.reconcile_offer(offer.id, dry_run: false, allow_repair: true)

    assert first.redis_available_after == second.redis_available_after
  end

  test "logs do not include buyer phone from checkout fixtures", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        buyer_phone: "+27999888777",
        idempotency_key: "recon-log-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    log =
      capture_log(fn ->
        assert {:ok, _} = Reconciler.reconcile_offer(offer.id, dry_run: true)
      end)

    refute log =~ "+27999888777"
    refute log =~ "buyer@example.com"
  end

  defp insert_paid_order!(offer_id, opts) do
    quantity = Keyword.get(opts, :quantity, 1)
    public_reference = "FC-RECON-#{System.unique_integer([:positive])}"

    result =
      Repo.query!(
        """
        WITH ord AS (
          INSERT INTO sales_orders
            (public_reference, event_id, buyer_name, source_channel, status,
             total_amount_cents, currency, inserted_at, updated_at)
          VALUES
            ($1, $2, 'Synthetic', 'test', 'paid_verified', 100, 'ZAR', now(), now())
          RETURNING id
        )
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        SELECT id, $3, 1, 'general', 'Offer', 'Event', $4, 100, 100, 'ZAR', '{}', now(), now()
        FROM ord
        RETURNING sales_order_id
        """,
        [public_reference, Fixtures.event_id(), offer_id, quantity]
      )

    [[order_id]] = result.rows
    order_id
  end
end
