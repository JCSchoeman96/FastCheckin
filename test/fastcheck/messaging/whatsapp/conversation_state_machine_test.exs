defmodule FastCheck.Messaging.WhatsApp.ConversationStateMachineTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Messaging.WhatsApp.ConversationStateMachine
  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.TestSupport, as: PaymentSupport
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheckWeb.SalesWebFixtures

  setup do
    paystack_cleanup = PaymentSupport.setup_paystack!()

    WebhookTestSupport.flush_redis_keys!()

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Voelgoed Live",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "General", max_per_order: 4)

    on_exit(fn ->
      paystack_cleanup.()
      SalesFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
    end)

    conversation = insert_conversation!()

    {:ok, event: event, offer: offer, conversation: conversation}
  end

  test "customer can reach payment_pending through number-only flow", %{
    conversation: conversation,
    event: event,
    offer: offer
  } do
    assert {:ok, result} = handle(conversation, "hi", "wamid.flow-1")
    assert result.conversation.state == "selecting_language"
    assert result.response_body =~ "Welkom by FastCheck Tickets"

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-2")
    assert result.conversation.state == "main_menu"
    assert result.response_body =~ "Koop kaartjies"

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-3")
    assert result.conversation.state == "selecting_event"
    assert result.response_body =~ "Voelgoed Live"
    refute result.response_body =~ to_string(event.id)

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-4")
    assert result.conversation.state == "selecting_ticket_type"
    assert result.response_body =~ "General"
    refute result.response_body =~ to_string(offer.id)

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-5")
    assert result.conversation.state == "collecting_quantity"

    assert {:ok, result} = handle(result.conversation, "2", "wamid.flow-6")
    assert result.conversation.state == "collecting_buyer_name"

    assert {:ok, result} = handle(result.conversation, "Jan Burger", "wamid.flow-7")
    assert result.conversation.state == "collecting_email"

    assert {:ok, result} = handle(result.conversation, "jan@example.com", "wamid.flow-8")
    assert result.conversation.state == "confirming_order"
    assert result.response_body =~ "Bevestig"

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-9")
    assert result.conversation.state == "payment_pending"
    assert result.response_body =~ "betaling"
    refute result.response_body =~ "https://"

    state_data = result.conversation.state_data
    assert state_data["selected_event_id"] == event.id
    assert state_data["selected_offer_id"] == offer.id
    assert state_data["quantity"] == 2
    assert state_data["buyer_name"] == "Jan Burger"
    assert state_data["buyer_email"] == "jan@example.com"
    assert is_integer(state_data["sales_order_id"])
    assert is_integer(state_data["payment_attempt_id"])
    assert is_binary(state_data["order_public_reference"])

    assert {:ok, session} = SessionStore.get_session_by_wa_id("27821234567")
    refute Map.has_key?(session, "buyer_name")
    refute inspect(session) =~ "Jan Burger"

    order_id = state_data["sales_order_id"]

    assert [order] =
             Order
             |> Query.filter(id == ^order_id)
             |> Ash.read!(authorize?: false)

    assert order.status == "awaiting_payment"
    assert order.event_id == event.id
    assert order.buyer_phone == "+27821234567"

    assert_enqueued(
      worker: SendWhatsAppPaymentLinkWorker,
      args: %{
        "conversation_id" => result.conversation.id,
        "sales_order_id" => state_data["sales_order_id"],
        "payment_attempt_id" => state_data["payment_attempt_id"]
      }
    )
  end

  test "duplicate confirm uses checkout idempotency and creates one order", %{
    conversation: conversation
  } do
    result =
      conversation
      |> progress("hi", "1")
      |> progress("1", "2")
      |> progress("1", "3")
      |> progress("1", "4")
      |> progress("1", "5")
      |> progress("1", "6")
      |> progress("Jan Burger", "7")
      |> progress("jan@example.com", "8")

    assert result.conversation.state == "confirming_order"

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    assert {:ok, first} = handle(result.conversation, "1", "wamid.dup-9")
    assert {:ok, second} = handle(first.conversation, "1", "wamid.dup-10")

    assert first.conversation.state == "payment_pending"
    assert second.conversation.state == "payment_pending"

    assert first.conversation.state_data["sales_order_id"] ==
             second.conversation.state_data["sales_order_id"]

    order_id = first.conversation.state_data["sales_order_id"]

    assert 1 =
             Order
             |> Query.filter(id == ^order_id)
             |> Ash.read!(authorize?: false)
             |> length()
  end

  test "redis session loss recovers from durable conversation checkpoint", %{
    conversation: conversation
  } do
    result =
      conversation
      |> progress("hi", "1")
      |> progress("1", "2")
      |> progress("1", "3")

    assert result.conversation.state == "selecting_event"
    WebhookTestSupport.flush_redis_keys!()

    assert {:ok, recovered} = handle(result.conversation, "0", "wamid.recover-4")
    assert recovered.conversation.state == "main_menu"
    assert recovered.response_body =~ "Koop kaartjies"
  end

  test "invalid input repeats current menu without advancing state", %{conversation: conversation} do
    assert {:ok, result} = handle(conversation, "hi", "wamid.invalid-1")
    assert {:ok, repeated} = handle(result.conversation, "ten", "wamid.invalid-2")

    assert repeated.conversation.state == "selecting_language"
    assert repeated.response_body =~ "Antwoord asseblief"
    assert repeated.response_body =~ "Welkom by FastCheck Tickets"
  end

  defp progress(%{conversation: conversation}, text, suffix),
    do: progress(conversation, text, suffix)

  defp progress(%Conversation{} = conversation, text, suffix) do
    assert {:ok, result} = handle(conversation, text, "wamid.progress-#{suffix}")
    result
  end

  defp handle(conversation, text, provider_message_id) do
    command = %MessageCommand{
      provider: "meta",
      provider_message_id: provider_message_id,
      phone_e164: "+27821234567",
      wa_id: "27821234567",
      message_type: "text",
      text_body: text,
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      raw_payload_hash: "hash-#{provider_message_id}",
      correlation_id: "corr-#{provider_message_id}",
      metadata: %{}
    }

    ConversationStateMachine.handle_inbound(command, conversation)
  end

  defp insert_conversation! do
    %{rows: [[id]]} =
      Repo.query!("""
      INSERT INTO sales_conversations
        (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
      VALUES
        ('+27821234567', '27821234567', 'af', 'new', '{}', false, now(), now())
      RETURNING id
      """)

    Conversation
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
