defmodule FastCheck.Messaging.WhatsApp.EventSalesGateTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events.Event
  alias FastCheck.Messaging.WhatsApp.ConversationStateMachine
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Conversation
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheckWeb.SalesWebFixtures

  setup do
    WebhookTestSupport.flush_redis_keys!()

    event =
      SalesWebFixtures.insert_event!(%{
        name: "WhatsApp Gate Event",
        scanner_login_code: scanner_code(),
        whatsapp_sales_enabled: true
      })

    offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "Gate General",
        max_per_order: 12
      )

    on_exit(fn ->
      SalesFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
    end)

    {:ok, event: event, offer: offer}
  end

  test "disabled events are absent from new WhatsApp discovery", %{event: event, offer: offer} do
    disable_whatsapp_sales!(event)
    conversation = insert_conversation!(event)

    assert {:ok, result} =
             ConversationStateMachine.handle_inbound(command("wamid.gate-disabled"), conversation)

    assert result.conversation.state == "main_menu"
    assert result.response_body =~ "kaartjies beskikbaar"
    refute result.response_body =~ offer.name
  end

  test "new events default to WhatsApp sales disabled" do
    event =
      SalesWebFixtures.insert_event!(%{
        name: "WhatsApp Gate Default Event",
        scanner_login_code: scanner_code()
      })

    assert event.whatsapp_sales_enabled == false
  end

  test "enabled events with an active WhatsApp offer are discoverable", %{event: event} do
    conversation = insert_conversation!(event)

    assert {:ok, result} =
             ConversationStateMachine.handle_inbound(command("wamid.gate-enabled"), conversation)

    assert result.conversation.state == "selecting_event"
    assert result.response_body =~ event.name
  end

  test "enabled events without an active WhatsApp offer are absent from discovery" do
    event =
      SalesWebFixtures.insert_event!(%{
        name: "WhatsApp Gate Empty Event",
        scanner_login_code: scanner_code(),
        whatsapp_sales_enabled: true
      })

    conversation = insert_conversation!(event)

    assert {:ok, result} =
             ConversationStateMachine.handle_inbound(command("wamid.gate-empty"), conversation)

    assert result.conversation.state == "selecting_event"
    refute result.response_body =~ event.name
  end

  test "archived events are absent from discovery", %{event: event} do
    event
    |> Event.changeset(%{status: "archived"})
    |> Repo.update!()

    conversation = insert_conversation!(event)

    assert {:ok, result} =
             ConversationStateMachine.handle_inbound(command("wamid.gate-archived"), conversation)

    assert result.conversation.state == "main_menu"
    refute result.response_body =~ event.name
  end

  test "stale confirmation fails safely after WhatsApp sales are disabled", %{
    event: event,
    offer: offer
  } do
    conversation =
      insert_conversation!(event,
        state: "confirming_order",
        state_data: %{
          "selected_event_id" => event.id,
          "selected_event_label" => event.name,
          "selected_offer_id" => offer.id,
          "selected_offer_label" => offer.name,
          "selected_offer_max_per_order" => offer.max_per_order,
          "selected_offer_price_cents" => offer.price_cents,
          "selected_offer_currency" => offer.currency,
          "quantity" => 1,
          "buyer_name" => "Gate Buyer",
          "buyer_email" => "gate@example.com"
        }
      )

    disable_whatsapp_sales!(event)
    order_count = Repo.aggregate("sales_orders", :count, :id)
    hold_count = Repo.aggregate("sales_checkout_sessions", :count, :id)

    assert {:ok, result} =
             ConversationStateMachine.handle_inbound(
               command("wamid.gate-stale-confirmation"),
               conversation
             )

    assert result.conversation.state == "main_menu"
    assert result.response_body =~ "WhatsApp-verkope"
    assert Repo.aggregate("sales_orders", :count, :id) == order_count
    assert Repo.aggregate("sales_checkout_sessions", :count, :id) == hold_count
  end

  test "direct WhatsApp checkout re-checks the event gate without creating an order or hold", %{
    event: event,
    offer: offer
  } do
    disable_whatsapp_sales!(event)

    input = checkout_input(event, offer, "gate-direct")
    order_count = Repo.aggregate("sales_orders", :count, :id)
    hold_count = Repo.aggregate("sales_checkout_sessions", :count, :id)

    assert {:error, :whatsapp_sales_disabled} =
             Checkout.start_checkout(input, customer_actor(event.id),
               effective_sales_channel: "whatsapp"
             )

    assert Repo.aggregate("sales_orders", :count, :id) == order_count
    assert Repo.aggregate("sales_checkout_sessions", :count, :id) == hold_count
  end

  test "an existing checkout replays after the WhatsApp gate is disabled", %{
    event: event,
    offer: offer
  } do
    input = checkout_input(event, offer, "gate-replay")

    assert {:ok, first_checkout} =
             Checkout.start_checkout(input, customer_actor(event.id),
               effective_sales_channel: "whatsapp"
             )

    disable_whatsapp_sales!(event)

    assert {:ok, replay} =
             Checkout.start_checkout(input, customer_actor(event.id),
               effective_sales_channel: "whatsapp"
             )

    assert replay.order.id == first_checkout.order.id
    assert replay.checkout_session.id == first_checkout.checkout_session.id
  end

  test "the WhatsApp gate does not disable an admin checkout", %{event: event} do
    admin_offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "Admin General",
        sales_channel: "admin"
      )

    on_exit(fn -> SalesFixtures.flush_inventory_keys(admin_offer.id) end)
    disable_whatsapp_sales!(event)

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(
               checkout_input(event, admin_offer, "gate-admin", source_channel: "admin"),
               %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: [event.id]},
               effective_sales_channel: "admin"
             )

    assert order.source_channel == "admin"
  end

  defp disable_whatsapp_sales!(event) do
    event
    |> Event.changeset(%{whatsapp_sales_enabled: false})
    |> Repo.update!()
  end

  defp checkout_input(event, offer, suffix, opts \\ []) do
    source_channel = Keyword.get(opts, :source_channel, "whatsapp")

    %{
      event_id: event.id,
      ticket_offer_id: offer.id,
      quantity: 1,
      buyer_name: "Gate Buyer",
      buyer_phone: "+27821234567",
      buyer_email: "gate@example.com",
      source_channel: source_channel,
      idempotency_key: "#{suffix}-#{System.unique_integer([:positive])}",
      correlation_id: "corr-#{suffix}",
      event_name: event.name
    }
  end

  defp customer_actor(event_id),
    do: %{actor_type: :customer_session, actor_id: "gate-customer", allowed_event_ids: [event_id]}

  defp insert_conversation!(event, opts \\ []) do
    state = Keyword.get(opts, :state, "main_menu")
    state_data = Keyword.get(opts, :state_data, %{"selected_event_id" => event.id})

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES ('+27821234567', '27821234567', 'af', $1, $2, false, now(), now())
        RETURNING id
        """,
        [state, state_data]
      )

    Conversation
    |> Ash.Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp command(provider_message_id) do
    %MessageCommand{
      provider: "meta",
      provider_message_id: provider_message_id,
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: "1",
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      raw_payload_hash: "hash-#{provider_message_id}",
      correlation_id: "corr-#{provider_message_id}",
      metadata: %{}
    }
  end

  defp scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
