defmodule FastCheck.Messaging.WhatsApp.ActiveCommercialOrderTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Messaging.WhatsApp.ActiveCommercialOrder
  alias FastCheck.Messaging.WhatsApp.PurchaseFlowIdentity
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Conversation
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures

  setup do
    offer = SalesFixtures.insert_offer!()
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "modern purchase identity recovers an uncheckpointed active order", %{offer: offer} do
    purchase_flow_id = PurchaseFlowIdentity.new()

    conversation =
      insert_conversation!(51, "confirming_order", %{"purchase_flow_id" => purchase_flow_id})

    key = modern_key(conversation.id, purchase_flow_id)
    order = create_order!(conversation, offer, key)

    assert {:ok, found} = ActiveCommercialOrder.find_active_order(conversation)
    assert found.id == order.id
  end

  test "the legacy key recovers an in-flight conversation without a purchase identity", %{
    offer: offer
  } do
    conversation = insert_conversation!(52, "confirming_order", %{})

    order =
      create_order!(
        conversation,
        offer,
        PurchaseFlowIdentity.legacy_checkout_idempotency_key(conversation.id)
      )

    assert {:ok, found} = ActiveCommercialOrder.find_active_order(conversation)
    assert found.id == order.id
  end

  test "conversation order lookup repairs a checkpoint lost by the old restart", %{offer: offer} do
    conversation = insert_conversation!(53, "main_menu", %{})
    order = create_order!(conversation, offer, "legacy-lost-checkpoint-#{conversation.id}")

    assert {:ok, found} = ActiveCommercialOrder.find_active_order(conversation)
    assert found.id == order.id
  end

  test "multiple active orders fail closed instead of choosing one", %{offer: offer} do
    conversation = insert_conversation!(54, "main_menu", %{})
    create_order!(conversation, offer, "first-active-#{conversation.id}")
    create_order!(conversation, offer, "second-active-#{conversation.id}")

    assert {:error, :multiple_active_orders} =
             ActiveCommercialOrder.find_active_order(conversation)
  end

  test "a checkpoint linked to another conversation fails closed", %{offer: offer} do
    owner = insert_conversation!(55, "confirming_order", %{})
    order = create_order!(owner, offer, "foreign-order-#{owner.id}")
    other = insert_conversation!(56, "confirming_order", %{"sales_order_id" => order.id})

    assert {:error, :conversation_order_mismatch} = ActiveCommercialOrder.find_active_order(other)
  end

  test "terminal orders no longer block a later purchase", %{offer: offer} do
    conversation = insert_conversation!(57, "main_menu", %{})
    order = create_order!(conversation, offer, "terminal-order-#{conversation.id}")

    Repo.update_all(from(o in "sales_orders", where: o.id == ^order.id),
      set: [status: "ticket_issued"]
    )

    assert {:ok, nil} = ActiveCommercialOrder.find_active_order(conversation)
  end

  test "direct restart Ash action preserves an active Order hidden from state_data", %{
    offer: offer
  } do
    conversation = insert_conversation!(58, "payment_pending", %{})
    order = create_order!(conversation, offer, "hidden-restart-order-#{conversation.id}")

    assert {:ok, restarted} =
             conversation
             |> Changeset.for_update(
               :restart_to_main_menu,
               %{
                 state_data: %{},
                 last_inbound_message_id: "wamid.direct-restart",
                 last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 correlation_id: "corr-direct-restart",
                 idempotency_key: "idem-direct-restart",
                 transition_metadata: %{source_channel: "whatsapp"}
               },
               actor: %{actor_type: :system, actor_id: "active-order-test"}
             )
             |> Ash.update(authorize?: false)

    assert Repo.one!(
             from c in "sales_conversations",
               where: c.id == ^conversation.id,
               select: c.state
           ) == "main_menu"

    assert restarted.state_data["sales_order_id"] == order.id

    assert Repo.one!(
             from o in "sales_orders",
               where: o.id == ^order.id,
               select: o.status
           ) == "awaiting_payment"
  end

  test "direct resend Ash actions reject an active Order", %{offer: offer} do
    cases = [
      {:submit_resend_name, "collecting_resend_name"},
      {:submit_resend_email, "collecting_resend_email"},
      {:return_to_resend_name_collection, "collecting_resend_email"},
      {:return_to_resend_email_collection, "collecting_resend_otp"},
      {:verify_resend_otp, "collecting_resend_otp"},
      {:queue_verified_resend_delivery, "awaiting_verified_resend_delivery"}
    ]

    for {{action, state}, index} <- Enum.with_index(cases, 1) do
      conversation = insert_conversation!(58 + index, state, %{})
      order = create_order!(conversation, offer, "direct-resend-#{action}-#{conversation.id}")

      assert {:error, _reason} =
               conversation
               |> Changeset.for_update(
                 action,
                 %{
                   state_data: %{},
                   last_inbound_message_id: "wamid.direct-#{action}",
                   last_message_at: DateTime.utc_now() |> DateTime.truncate(:second),
                   correlation_id: "corr-direct-#{action}",
                   idempotency_key: "idem-direct-#{action}",
                   transition_metadata: %{source_channel: "whatsapp"}
                 },
                 actor: %{actor_type: :system, actor_id: "active-order-test"}
               )
               |> Ash.update(authorize?: false)

      assert Repo.one!(
               from c in "sales_conversations",
                 where: c.id == ^conversation.id,
                 select: c.state
             ) == state

      assert Repo.one!(
               from o in "sales_orders",
                 where: o.id == ^order.id,
                 select: o.status
             ) == "awaiting_payment"
    end
  end

  defp create_order!(conversation, offer, idempotency_key) do
    input =
      SalesFixtures.checkout_input(%{
        event_id: offer.event_id,
        ticket_offer_id: offer.id,
        buyer_phone: conversation.phone_e164,
        source_channel: "whatsapp",
        sales_conversation_id: conversation.id,
        idempotency_key: idempotency_key,
        expected_offer_lock_version: offer.lock_version
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, SalesFixtures.system_actor([offer.event_id]),
               effective_sales_channel: "whatsapp"
             )

    order
  end

  defp insert_conversation!(number, state, state_data) do
    phone = "+2782123#{String.pad_leading(Integer.to_string(number), 4, "0")}"
    wa_id = String.replace_prefix(phone, "+", "")

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES ($1, $2, 'en', $3, $4, false, now(), now())
        RETURNING id
        """,
        [phone, wa_id, state, state_data]
      )

    Conversation
    |> Ash.Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp modern_key(conversation_id, purchase_flow_id) do
    {:ok, key} = PurchaseFlowIdentity.checkout_idempotency_key(conversation_id, purchase_flow_id)
    key
  end
end
