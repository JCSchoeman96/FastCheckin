defmodule FastCheck.Sales.WhatsAppSalesGateTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  test "new WhatsApp checkout fails closed before creating sales or inventory state" do
    event = create_event(%{name: "Checkout gate off"})
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input = checkout_input(event, offer, "gate-off")
    before = availability_snapshot!(offer.id)

    assert {:error, :whatsapp_sales_disabled} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert 0 == Repo.aggregate(from(o in "sales_orders", where: o.event_id == ^event.id), :count)
    assert 0 == Repo.aggregate(from(l in "sales_order_lines"), :count)
    assert 0 == Repo.aggregate(from(s in "sales_checkout_sessions"), :count)
    assert 0 == Repo.aggregate(from(p in "sales_payment_attempts"), :count)
    assert before == availability_snapshot!(offer.id)
  end

  test "enabled WhatsApp checkout keeps existing checkout behavior" do
    event = create_event(%{name: "Checkout gate on"})
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

    assert {:ok, %{order: order, checkout_session: session}} =
             Checkout.start_checkout(
               checkout_input(event, offer, "gate-on"),
               Fixtures.customer_session_actor([event.id])
             )

    assert order.event_id == event.id
    assert session.sales_order_id == order.id
  end

  test "the fresh WhatsApp gate reads durable state instead of the Event cache" do
    event = create_event(%{name: "Checkout durable gate"})
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    assert :ok = Cache.persist_event_cache(event)

    assert {1, nil} =
             Repo.update_all(from(e in "events", where: e.id == ^event.id),
               set: [whatsapp_sales_enabled: true]
             )

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(
               checkout_input(event, offer, "durable-cache-bypass"),
               Fixtures.customer_session_actor([event.id])
             )

    assert order.event_id == event.id
    assert :ok = Cache.invalidate_event_cache(event.id)
  end

  test "admin, web, and internal checkout channels ignore the WhatsApp event gate" do
    event = create_event(%{name: "Non WhatsApp channels"})
    admin_offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "admin")
    all_offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "all")
    internal_offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "internal")

    on_exit(fn ->
      Fixtures.flush_inventory_keys(admin_offer.id)
      Fixtures.flush_inventory_keys(all_offer.id)
      Fixtures.flush_inventory_keys(internal_offer.id)
    end)

    assert {:ok, %{order: admin_order}} =
             Checkout.start_checkout(
               checkout_input(event, admin_offer, "admin-off", source_channel: "admin"),
               Fixtures.admin_actor([event.id])
             )

    assert {:ok, %{order: web_order}} =
             Checkout.start_checkout(
               checkout_input(event, all_offer, "web-off", source_channel: "web"),
               Fixtures.system_actor([event.id])
             )

    assert {:ok, %{order: internal_order}} =
             Checkout.start_checkout(
               checkout_input(
                 event,
                 internal_offer,
                 "internal-off",
                 source_channel: "internal_pilot"
               ),
               Fixtures.admin_actor([event.id])
             )

    assert admin_order.source_channel == "admin"
    assert web_order.source_channel == "web"
    assert internal_order.source_channel == "internal_pilot"
  end

  test "an exact WhatsApp idempotent replay still works after the gate is disabled" do
    event = create_event(%{name: "Replay after disable"})
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

    input = checkout_input(event, offer, "replay-after-disable")
    actor = Fixtures.customer_session_actor([event.id])

    assert {:ok, first} = Checkout.start_checkout(input, actor)
    assert {:ok, _} = Events.disable_whatsapp_sales(event.id)

    assert {:ok, replay} = Checkout.start_checkout(input, actor)
    assert replay.order.id == first.order.id
    assert replay.checkout_session.id == first.checkout_session.id
    assert availability_snapshot!(offer.id).reserved_quantity == 1
  end

  defp availability_snapshot!(offer_id) do
    assert {:ok, snapshot} = ReservationLedger.get_availability(offer_id)
    snapshot
  end

  defp checkout_input(event, offer, suffix, opts \\ []) do
    Fixtures.checkout_input(%{
      event_id: event.id,
      ticket_offer_id: offer.id,
      source_channel: Keyword.get(opts, :source_channel, "whatsapp"),
      event_name: event.name,
      idempotency_key: "whatsapp-gate-#{suffix}-#{System.unique_integer([:positive])}"
    })
  end
end
