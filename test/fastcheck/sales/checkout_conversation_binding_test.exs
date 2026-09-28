defmodule FastCheck.Sales.CheckoutConversationBindingTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!(sales_channel: "whatsapp", max_per_order: 10)
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "WhatsApp checkout requires an explicit conversation before reserving inventory", %{
    offer: offer
  } do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        sales_conversation_id: nil
      })

    assert {:ok, before} = ReservationLedger.get_availability(offer.id)
    order_count = Repo.aggregate(from(o in "sales_orders"), :count)

    assert {:error, :sales_conversation_required} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([offer.event_id]))

    assert Repo.aggregate(from(o in "sales_orders"), :count) == order_count
    assert {:ok, ^before} = ReservationLedger.get_availability(offer.id)
  end

  test "WhatsApp checkout stores the exact conversation foreign key", %{offer: offer} do
    conversation_id = insert_conversation!("+27123456789")

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        sales_conversation_id: conversation_id
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([offer.event_id]))

    assert order.sales_conversation_id == conversation_id
  end

  test "WhatsApp checkout rejects a conversation whose phone differs from the buyer", %{
    offer: offer
  } do
    conversation_id = insert_conversation!("+27821234567")

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        buyer_phone: "+27123456789",
        source_channel: "whatsapp",
        sales_conversation_id: conversation_id
      })

    assert {:ok, before} = ReservationLedger.get_availability(offer.id)

    assert {:error, :sales_conversation_phone_mismatch} =
             Checkout.start_checkout(input, Fixtures.customer_session_actor([offer.event_id]))

    assert {:ok, ^before} = ReservationLedger.get_availability(offer.id)
    assert Repo.aggregate(from(o in "sales_orders"), :count) == 0
  end

  test "idempotent WhatsApp replay cannot change its conversation binding", %{offer: offer} do
    first_conversation_id = insert_conversation!("+27123456789")
    other_conversation_id = insert_conversation!("+27123456789")

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        sales_conversation_id: first_conversation_id,
        idempotency_key: "conversation-replay-#{System.unique_integer([:positive])}"
      })

    actor = Fixtures.customer_session_actor([offer.event_id])

    assert {:ok, %{order: order}} = Checkout.start_checkout(input, actor)

    assert {:error, :duplicate_idempotency_conflict} =
             Checkout.start_checkout(
               Map.put(input, :sales_conversation_id, other_conversation_id),
               actor
             )

    assert Repo.one!(from(o in "sales_orders", select: count(o.id))) == 1

    assert Repo.one!(from(o in "sales_orders", select: max(o.sales_conversation_id))) ==
             first_conversation_id

    assert order.sales_conversation_id == first_conversation_id
  end

  defp insert_conversation!(phone_e164) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES ($1, $2, 'en', 'confirming_order', '{}', false, now(), now())
        RETURNING id
        """,
        [phone_e164, "wa-#{System.unique_integer([:positive])}"]
      )

    id
  end
end
