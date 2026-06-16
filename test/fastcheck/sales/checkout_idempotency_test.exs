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

  test "duplicate idempotency key with conflicting ticket_offer_id returns conflict", %{
    offer: offer
  } do
    other_offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(other_offer.id) end)

    idem = "idem-offer-#{System.unique_integer([:positive])}"

    base =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(base, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    conflict = Map.put(base, :ticket_offer_id, other_offer.id)

    assert {:error, :duplicate_idempotency_conflict} =
             Checkout.start_checkout(conflict, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "duplicate idempotency key with conflicting quantity returns conflict", %{offer: offer} do
    idem = "idem-quantity-#{System.unique_integer([:positive])}"

    base =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 1,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(base, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    conflict = Map.put(base, :quantity, 2)

    assert {:error, :duplicate_idempotency_conflict} =
             Checkout.start_checkout(conflict, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "duplicate idempotency key with conflicting effective_sales_channel returns conflict" do
    all_channel_offer = Fixtures.insert_offer!(sales_channel: "all")
    on_exit(fn -> Fixtures.flush_inventory_keys(all_channel_offer.id) end)

    idem = "idem-channel-#{System.unique_integer([:positive])}"

    base =
      Fixtures.checkout_input(%{
        ticket_offer_id: all_channel_offer.id,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(base, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:error, :duplicate_idempotency_conflict} =
             Checkout.start_checkout(base, Fixtures.system_actor(),
               effective_sales_channel: "web"
             )
  end
end
