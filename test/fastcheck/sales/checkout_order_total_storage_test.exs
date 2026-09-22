defmodule FastCheck.Sales.CheckoutOrderTotalStorageTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query
  require Ash.Query

  alias FastCheck.Events
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.OrderLine
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  @max_postgres_integer 2_147_483_647

  test "fresh checkout rejects total above PostgreSQL INTEGER before any side effects" do
    event = create_event(%{name: "H07 overflow boundary"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 12)

    offer =
      Fixtures.insert_offer!(
        event_id: event.id,
        sales_channel: "whatsapp",
        max_per_order: 12,
        price_cents: 200_000_000
      )

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 12,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "total-overflow-12-#{System.unique_integer([:positive])}"
      })

    before = availability_snapshot!(offer.id)

    assert {:error, :order_total_too_large} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert_zero_checkout_side_effects!(event.id)
    assert before == availability_snapshot!(offer.id)

    ok_input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 9,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "total-ok-9-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(ok_input, Fixtures.customer_session_actor([event.id]))

    assert order.total_amount_cents == 1_800_000_000

    assert [%{quantity: 9, total_amount_cents: 1_800_000_000}] =
             OrderLine
             |> Ash.Query.for_read(:list_for_order, %{sales_order_id: order.id})
             |> Ash.read!(authorize?: false)
  end

  test "storage guard accepts total exactly at INTEGER max" do
    event = create_event(%{name: "INTEGER max edge"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

    offer =
      Fixtures.insert_offer!(
        event_id: event.id,
        sales_channel: "whatsapp",
        max_per_order: 1,
        price_cents: @max_postgres_integer
      )

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 1,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "int-max-ok-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert order.total_amount_cents == @max_postgres_integer
  end

  test "storage guard rejects total one unit above INTEGER max with zero side effects" do
    event = create_event(%{name: "INTEGER max overflow"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

    offer =
      Fixtures.insert_offer!(
        event_id: event.id,
        sales_channel: "whatsapp",
        max_per_order: 2,
        price_cents: @max_postgres_integer
      )

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 2,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "int-max-over-#{System.unique_integer([:positive])}"
      })

    before = availability_snapshot!(offer.id)

    assert {:error, :order_total_too_large} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([event.id]))

    assert_zero_checkout_side_effects!(event.id)
    assert before == availability_snapshot!(offer.id)
  end

  test "exact idempotent replay skips storage guard after later cap or price context changes" do
    event = create_event(%{name: "Idempotent storage replay"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 12)

    offer =
      Fixtures.insert_offer!(
        event_id: event.id,
        sales_channel: "whatsapp",
        max_per_order: 12,
        price_cents: 200_000_000
      )

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        quantity: 9,
        source_channel: "whatsapp",
        event_name: event.name,
        idempotency_key: "storage-replay-#{System.unique_integer([:positive])}"
      })

    actor = Fixtures.customer_session_actor([event.id])
    assert {:ok, first} = Checkout.start_checkout(input, actor)
    reserved_before = availability_snapshot!(offer.id).reserved_quantity

    assert {:ok, replay} = Checkout.start_checkout(input, actor)
    assert replay.order.id == first.order.id
    assert availability_snapshot!(offer.id).reserved_quantity == reserved_before
  end

  defp assert_zero_checkout_side_effects!(event_id) do
    assert 0 == Repo.aggregate(from(o in "sales_orders", where: o.event_id == ^event_id), :count)
    assert 0 == Repo.aggregate(from(l in "sales_order_lines"), :count)
    assert 0 == Repo.aggregate(from(s in "sales_checkout_sessions"), :count)
    assert 0 == Repo.aggregate(from(p in "sales_payment_attempts"), :count)
  end

  defp availability_snapshot!(offer_id) do
    assert {:ok, snapshot} = ReservationLedger.get_availability(offer_id)
    snapshot
  end
end
