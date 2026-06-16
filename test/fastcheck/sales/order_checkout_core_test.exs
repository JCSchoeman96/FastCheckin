defmodule FastCheck.Sales.OrderCheckoutCoreTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.StateTransition
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "valid checkout creates order, line, session, hold, and transitions", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "test",
        idempotency_key: "core-happy-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order, checkout_session: session}} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert order.status == "awaiting_payment"
    assert session.status == "hold_attached"
    assert session.redis_hold_key == ReservationLedger.hold_key(order.public_reference)
    assert session.hold_quantity == 1
    assert session.hold_token == nil

    order_id = order.id

    assert [%OrderLine{} = line] =
             OrderLine
             |> Query.for_read(:list_for_order, %{sales_order_id: order_id})
             |> Ash.read!(authorize?: false)

    assert line.offer_name_snapshot == offer.name
    assert line.total_amount_cents == offer.price_cents

    order_transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{entity_type: "Order", entity_id: to_string(order.id)})
      |> Ash.read!(authorize?: false)

    assert Enum.any?(order_transitions, &(&1.to_state == "awaiting_payment"))

    session_transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "CheckoutSession",
        entity_id: to_string(session.id)
      })
      |> Ash.read!(authorize?: false)

    assert Enum.any?(session_transitions, &(&1.to_state == "hold_attached"))
  end

  test "checkout rejects disabled offer" do
    offer = Fixtures.insert_offer!(sales_enabled: false)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "disabled-#{System.unique_integer([:positive])}"
      })

    assert {:error, :sales_disabled} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "checkout rejects closed sales window" do
    future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)
    offer = Fixtures.insert_offer!(starts_at: future)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "window-#{System.unique_integer([:positive])}"
      })

    assert {:error, :sales_window_closed} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "checkout rejects quantity over max_per_order", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: offer.max_per_order + 1,
        idempotency_key: "max-#{System.unique_integer([:positive])}"
      })

    assert {:error, :max_per_order_exceeded} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "checkout rejects wrong sales channel" do
    offer = Fixtures.insert_offer!(sales_channel: "admin")

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "channel-#{System.unique_integer([:positive])}"
      })

    assert {:error, :sales_channel_unavailable} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "test source without effective_sales_channel is rejected", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "no-effective-#{System.unique_integer([:positive])}"
      })

    assert {:error, :invalid_effective_sales_channel} =
             Checkout.start_checkout(input, Fixtures.system_actor(), [])
  end

  test "checkout fails closed when inventory ledger is unavailable", %{offer: offer} do
    Fixtures.flush_inventory_keys(offer.id)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "no-redis-#{System.unique_integer([:positive])}"
      })

    assert {:error, :inventory_unavailable} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "checkout does not create awaiting_payment order when reserve fails", %{offer: offer} do
    :ok = ReservationLedger.initialize_offer(offer.id, 0)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "insufficient-#{System.unique_integer([:positive])}"
      })

    assert {:error, :insufficient_inventory} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    refute Order
           |> Query.filter(status == "awaiting_payment")
           |> Ash.exists?(authorize?: false)

    refute CheckoutSession
           |> Query.filter(status == "hold_attached")
           |> Ash.exists?(authorize?: false)
  end

  test "checkout logs do not include PII or tokens", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        buyer_name: "Secret Name",
        buyer_email: "secret@example.com",
        idempotency_key: "log-redact-#{System.unique_integer([:positive])}"
      })

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 Checkout.start_checkout(input, Fixtures.system_actor(),
                   effective_sales_channel: "whatsapp"
                 )
      end)

    refute log =~ "Secret Name"
    refute log =~ "secret@example.com"
    refute log =~ input.idempotency_key
  end
end
