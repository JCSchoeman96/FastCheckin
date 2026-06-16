defmodule FastCheck.Sales.CheckoutIdempotencyTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "checkout is idempotent by idempotency key", %{offer: offer} do
    idem = "idem-stable-#{System.unique_integer([:positive])}"

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    actor = Fixtures.system_actor()
    opts = [effective_sales_channel: "whatsapp"]

    assert {:ok, first} = Checkout.start_checkout(input, actor, opts)
    assert {:ok, second} = Checkout.start_checkout(input, actor, opts)

    assert first.order.id == second.order.id
    assert first.checkout_session.id == second.checkout_session.id

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.reserved_quantity == 1
  end

  test "duplicate idempotency key with conflicting event returns conflict", %{offer: offer} do
    idem = "idem-conflict-#{System.unique_integer([:positive])}"

    base =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(base, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    conflict = Map.put(base, :event_id, offer.event_id + 99)

    assert {:error, :duplicate_idempotency_conflict} =
             Checkout.start_checkout(conflict, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end
end
