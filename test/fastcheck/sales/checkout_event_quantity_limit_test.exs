defmodule FastCheck.Sales.CheckoutEventQuantityLimitTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  require Ash.Query

  alias FastCheck.Events
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.OrderLine
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  test "fresh WhatsApp checkout rejects quantity above the event cap with zero side effects" do
    event = create_event(%{name: "Event cap checkout"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)

    offer =
      Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp", max_per_order: 5)

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 3,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "event-cap-exceed-#{System.unique_integer([:positive])}"
      })

    before = availability_snapshot!(offer.id)

    assert {:error, :event_max_per_order_exceeded} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert 0 == Repo.aggregate(from(o in "sales_orders", where: o.event_id == ^event.id), :count)
    assert 0 == Repo.aggregate(from(l in "sales_order_lines"), :count)
    assert 0 == Repo.aggregate(from(s in "sales_checkout_sessions"), :count)
    assert 0 == Repo.aggregate(from(p in "sales_payment_attempts"), :count)
    assert before == availability_snapshot!(offer.id)
  end

  test "fresh WhatsApp checkout succeeds within the event cap" do
    event = create_event(%{name: "Event cap success"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)

    offer =
      Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp", max_per_order: 5)

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 2,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "event-cap-ok-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert order.event_id == event.id
  end

  test "offer max still applies when it is lower than the event cap" do
    event = create_event(%{name: "Offer max lower"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 5)

    offer =
      Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp", max_per_order: 2)

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 3,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "offer-max-lower-#{System.unique_integer([:positive])}"
      })

    assert {:error, :max_per_order_exceeded} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))
  end

  test "admin checkout ignores the WhatsApp event cap" do
    event = create_event(%{name: "Admin ignores cap"})
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)

    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "admin", max_per_order: 3)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 3,
        source_channel: "admin",
        event_name: event.name,
        idempotency_key: "admin-cap-ignore-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.admin_actor([event.id]))

    assert order.source_channel == "admin"
  end

  test "system checkout with effective WhatsApp channel is constrained by the event cap" do
    event = create_event(%{name: "Effective whatsapp cap"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)

    offer =
      Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp", max_per_order: 5)

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 3,
        source_channel: "test",
        event_name: event.name,
        idempotency_key: "effective-cap-#{System.unique_integer([:positive])}"
      })

    assert {:error, :event_max_per_order_exceeded} =
             Checkout.start_checkout(input, Fixtures.system_actor([event.id]),
               effective_sales_channel: "whatsapp"
             )
  end

  test "exact idempotent replay survives a later event cap decrease" do
    event = create_event(%{name: "Idempotent cap replay"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 5)

    offer =
      Fixtures.insert_offer!(event_id: event.id, sales_channel: "whatsapp", max_per_order: 5)

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 4,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "idempotent-cap-#{System.unique_integer([:positive])}"
      })

    actor = Fixtures.customer_session_actor([event.id])
    assert {:ok, first} = Checkout.start_checkout(input, actor)
    reserved_before = availability_snapshot!(offer.id).reserved_quantity
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)

    assert {:ok, replay} = Checkout.start_checkout(input, actor)
    assert replay.order.id == first.order.id
    assert replay.checkout_session.id == first.checkout_session.id
    assert availability_snapshot!(offer.id).reserved_quantity == reserved_before

    assert [%{quantity: 4}] =
             OrderLine
             |> Ash.Query.for_read(:list_for_order, %{sales_order_id: first.order.id})
             |> Ash.read!(authorize?: false)
  end

  defp availability_snapshot!(offer_id) do
    assert {:ok, snapshot} = ReservationLedger.get_availability(offer_id)
    snapshot
  end
end
