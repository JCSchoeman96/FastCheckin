defmodule FastCheck.Sales.Inventory.RecoveryTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.Recovery
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!(configured_quantity_available: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "rebuild_offer_inventory rebuilds redis after simulated key loss", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 2,
        idempotency_key: "recovery-rebuild-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:ok, _} = Redix.command(FastCheck.Redix, ["DEL", "sales:offer:#{offer.id}:inventory"])
    assert {:error, :reconciliation_required, _} = ReservationLedger.get_availability(offer.id)

    assert {:ok, report} =
             Recovery.rebuild_offer_inventory(offer.id, dry_run: false, allow_repair: true)

    assert report.repair_applied?

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.available_quantity == 8
    assert snapshot.reserved_quantity == 2
    assert snapshot.ledger_state == :healthy
  end

  test "repair_stale_holds releases only expired unpaid holds", %{offer: offer} do
    order_ref = "ORD-EXP-#{System.unique_integer([:positive])}"
    idem = "idem-exp-#{System.unique_integer([:positive])}"

    assert {:ok, _} = ReservationLedger.reserve(offer.id, order_ref, 1, 1, idem)

    now = System.system_time(:millisecond) + 5_000

    assert {:ok, report} =
             Recovery.repair_stale_holds(offer.id, now, dry_run: false, allow_repair: true)

    assert report.expired_count == 1

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.available_quantity == 10
    assert snapshot.reserved_quantity == 0
  end

  test "repair_stale_holds does not release consumed holds", %{offer: offer} do
    order_ref = "ORD-CONSUMED-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             ReservationLedger.reserve(offer.id, order_ref, 1, 120, "idem-reserve-#{order_ref}")

    assert {:ok, _} =
             ReservationLedger.consume(offer.id, order_ref, 1, "idem-consume-#{order_ref}")

    now = System.system_time(:millisecond) + 500_000

    assert {:ok, report} =
             Recovery.repair_stale_holds(offer.id, now, dry_run: false, allow_repair: true)

    assert report.expired_count == 0

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.consumed_quantity == 1
    assert snapshot.available_quantity == 9
    assert snapshot.reserved_quantity == 0
  end

  test "rebuild refuses when durable safe available is negative", %{offer: offer} do
    public_reference = "FC-NEG-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      WITH ord AS (
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency, inserted_at, updated_at)
        VALUES
          ($1, $2, 'test', 'paid_verified', 100, 'ZAR', now(), now())
        RETURNING id
      )
      INSERT INTO sales_order_lines
        (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
         event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
         metadata, inserted_at, updated_at)
      SELECT id, $3, 1, 'general', 'Offer', 'Event', 12, 100, 1200, 'ZAR', '{}', now(), now()
      FROM ord
      """,
      [public_reference, Fixtures.event_id(), offer.id]
    )

    assert {:manual_review_required, _} =
             Recovery.rebuild_offer_inventory(offer.id, dry_run: false, allow_repair: true)
  end
end
