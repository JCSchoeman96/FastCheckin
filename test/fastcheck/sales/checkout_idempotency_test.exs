defmodule FastCheck.Sales.CheckoutIdempotencyTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity
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

  test "concurrent duplicates for one WhatsApp purchase flow create one checkout", %{
    offer: offer
  } do
    purchase_flow_id = PurchaseFlowIdentity.new()

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        idempotency_key: "pending-whatsapp-key",
        expected_offer_lock_version: offer.lock_version
      })

    {:ok, idempotency_key} =
      PurchaseFlowIdentity.checkout_idempotency_key(
        input.sales_conversation_id,
        purchase_flow_id
      )

    Repo.query!("UPDATE sales_conversations SET state_data = $1 WHERE id = $2", [
      %{"purchase_flow_id" => purchase_flow_id},
      input.sales_conversation_id
    ])

    input = Map.put(input, :idempotency_key, idempotency_key)

    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          Checkout.start_checkout(input, Fixtures.system_actor(),
            effective_sales_channel: "whatsapp"
          )
        end,
        max_concurrency: 2,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successful_checkouts =
      Enum.filter(results, fn
        {:ok, %{order: _order, checkout_session: _session}} -> true
        _ -> false
      end)

    assert successful_checkouts != []

    assert Enum.all?(results, fn
             {:ok, %{order: _order, checkout_session: _session}} -> true
             {:error, :inventory_unavailable} -> true
             _ -> false
           end)

    order_ids = Enum.map(successful_checkouts, fn {:ok, checkout} -> checkout.order.id end)
    assert length(Enum.uniq(order_ids)) == 1
    order_id = hd(order_ids)
    first = elem(hd(successful_checkouts), 1)

    assert first.order.sales_conversation_id == input.sales_conversation_id
    assert first.order.idempotency_key == idempotency_key

    assert {:ok, replay} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert replay.order.id == order_id
    assert replay.checkout_session.id == first.checkout_session.id

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM sales_orders WHERE idempotency_key = $1", [
               idempotency_key
             ])

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM sales_order_lines WHERE sales_order_id = $1", [
               order_id
             ])

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM sales_checkout_sessions WHERE sales_order_id = $1",
               [
                 order_id
               ]
             )

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
