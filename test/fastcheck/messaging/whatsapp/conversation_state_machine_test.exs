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
  alias FastCheck.Sales.DeliveryAttempt
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.Payments.TestSupport, as: PaymentSupport
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheckWeb.SalesWebFixtures

  import FastCheck.TicketResendFixtures
  import Swoosh.TestAssertions

  setup :set_swoosh_global

  setup do
    paystack_cleanup = PaymentSupport.setup_paystack!()

    WebhookTestSupport.flush_redis_keys!()

    event =
      SalesWebFixtures.insert_event!(%{
        name: "Voelgoed Live",
        scanner_login_code: scanner_code()
      })

    offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "General",
        max_per_order: 4,
        price_cents: 1_000
      )

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
    assert result.response_body =~ "General - R10"
    refute exposes_raw_id?(result.response_body, offer.id)

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-5")
    assert result.conversation.state == "collecting_quantity"

    assert {:ok, result} = handle(result.conversation, "2", "wamid.flow-6")
    assert result.conversation.state == "collecting_buyer_name"

    assert {:ok, result} = handle(result.conversation, "Jan Burger", "wamid.flow-7")
    assert result.conversation.state == "collecting_email"

    assert {:ok, result} = handle(result.conversation, "jan@example.com", "wamid.flow-8")
    assert result.conversation.state == "confirming_order"
    assert result.response_body =~ "Bevestig jou bestelling:"
    assert result.response_body =~ "Naam: Jan Burger"
    assert result.response_body =~ "E-pos: jan@example.com"
    assert result.response_body =~ "Geleentheid: Voelgoed Live"
    assert result.response_body =~ "Kaartjie: General - R10"
    assert result.response_body =~ "Aantal: 2"
    assert result.response_body =~ "Totaal betaalbaar: R20"
    assert result.response_body =~ "Is hierdie korrek"
    assert result.response_body =~ "1. OK"
    assert result.response_body =~ "0. Terug"

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    assert {:ok, result} = handle(result.conversation, "1", "wamid.flow-9")
    assert result.conversation.state == "payment_pending"
    assert result.response_body =~ "betaling"
    refute result.response_body =~ "https://"

    state_data = result.conversation.state_data
    assert state_data["selected_event_id"] == event.id
    assert state_data["selected_offer_id"] == offer.id
    assert state_data["selected_offer_price_cents"] == 1_000
    assert state_data["selected_offer_currency"] == "ZAR"
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

  test "customer can request ticket resend OTP without ticket delivery side effects", %{
    conversation: conversation
  } do
    issued_ticket_candidate!(buyer_email: "resend@example.com", buyer_name: "Jamie Smith")

    result =
      conversation
      |> progress("hi", "resend-accepted-1")
      |> progress("1", "resend-accepted-2")

    assert result.conversation.state == "main_menu"

    assert {:ok, result} = handle(result.conversation, "3", "wamid.resend-accepted-3")
    assert result.conversation.state == "collecting_resend_name"
    assert result.response_body =~ "naam"

    assert {:ok, result} =
             handle(result.conversation, "  Jamie Smith  ", "wamid.resend-accepted-4")

    assert result.conversation.state == "collecting_resend_email"
    assert result.conversation.state_data["resend_name"] == "jamie smith"
    assert result.response_body =~ "e-pos"

    assert {:ok, result} =
             handle(result.conversation, "  RESEND@example.COM  ", "wamid.resend-accepted-5")

    assert result.conversation.state == "collecting_resend_otp"
    assert result.response_body =~ "verifikasiekode"
    refute result.response_body =~ "resend@example.com"
    refute String.downcase(result.response_body) =~ "ticket found"
    refute String.downcase(result.response_body) =~ "pdf"
    refute result.response_body =~ "http://"
    refute result.response_body =~ "https://"

    data = result.conversation.state_data
    assert data["resend_name"] == "jamie smith"
    assert data["resend_email"] == "resend@example.com"
    assert data["resend_email_otp_result_status"] == "accepted"
    assert data["resend_correlation_id"] == "corr-wamid.resend-accepted-5"
    assert is_binary(data["resend_requested_at"])
    assert is_binary(data["resend_challenge_public_id"])
    refute inspect(result.response_body) =~ data["resend_challenge_public_id"]

    assert_email_sent()
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
    assert delivery_attempt_count() == 0

    assert {:ok, session} = SessionStore.get_session_by_wa_id("27821234567")
    refute Map.has_key?(session, "resend_name")
    refute Map.has_key?(session, "resend_email")
    refute Map.has_key?(session, "resend_challenge_public_id")
    refute inspect(session) =~ "jamie smith"
    refute inspect(session) =~ "resend@example.com"
    refute inspect(session) =~ data["resend_challenge_public_id"]
  end

  test "generic rejected resend request uses same visible OTP prompt without challenge id", %{
    conversation: conversation
  } do
    accepted =
      conversation
      |> progress("hi", "resend-rejected-a1")
      |> progress("1", "resend-rejected-a2")
      |> progress("3", "resend-rejected-a3")
      |> progress("Jamie Smith", "resend-rejected-a4")
      |> progress("missing@example.com", "resend-rejected-a5")

    assert accepted.conversation.state == "collecting_resend_otp"

    assert accepted.conversation.state_data["resend_email_otp_result_status"] ==
             "generic_rejected"

    refute Map.has_key?(accepted.conversation.state_data, "resend_challenge_public_id")
    assert accepted.response_body =~ "verifikasiekode"
    assert_no_email_sent()
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)
    assert delivery_attempt_count() == 0
  end

  test "invalid resend name and email do not trigger EmailOtp", %{conversation: conversation} do
    result =
      conversation
      |> progress("hi", "resend-invalid-1")
      |> progress("1", "resend-invalid-2")
      |> progress("3", "resend-invalid-3")

    assert {:ok, blank_name} = handle(result.conversation, " ", "wamid.resend-invalid-4")
    assert blank_name.conversation.state == "collecting_resend_name"
    refute Map.has_key?(blank_name.conversation.state_data, "resend_name")

    assert {:ok, result} =
             handle(blank_name.conversation, "Jamie Smith", "wamid.resend-invalid-5")

    assert result.conversation.state == "collecting_resend_email"

    assert {:ok, bad_email} =
             handle(result.conversation, "not-an-email", "wamid.resend-invalid-6")

    assert bad_email.conversation.state == "collecting_resend_email"
    assert bad_email.response_body =~ "geldige e-posadres"
    refute Map.has_key?(bad_email.conversation.state_data, "resend_email")
    refute Map.has_key?(bad_email.conversation.state_data, "resend_email_otp_result_status")
    assert_no_email_sent()
  end

  test "resend OTP waiting state is inert and supports back and restart", %{
    conversation: conversation
  } do
    result =
      conversation
      |> progress("hi", "resend-otp-1")
      |> progress("1", "resend-otp-2")
      |> progress("3", "resend-otp-3")
      |> progress("Jamie Smith", "resend-otp-4")
      |> progress("missing@example.com", "resend-otp-5")

    assert result.conversation.state == "collecting_resend_otp"

    assert {:ok, repeated} = handle(result.conversation, "123456", "wamid.resend-otp-6")
    assert repeated.conversation.state == "collecting_resend_otp"
    assert repeated.response_body == result.response_body
    refute Map.has_key?(repeated.conversation.state_data, "verified_at")
    refute_enqueued(worker: SendWhatsAppTicketLinkWorker)

    assert {:ok, backed} = handle(repeated.conversation, "0", "wamid.resend-otp-7")
    assert backed.conversation.state == "collecting_resend_email"
    assert backed.response_body =~ "e-pos"
    refute Map.has_key?(backed.conversation.state_data, "resend_email")
    refute Map.has_key?(backed.conversation.state_data, "resend_email_otp_result_status")

    assert {:ok, restarted} = handle(backed.conversation, "#", "wamid.resend-otp-8")
    assert restarted.conversation.state == "main_menu"
    assert restarted.response_body =~ "Koop kaartjies"
    assert_resend_fields_absent(restarted.conversation.state_data)
  end

  test "confirmation summary renders skipped email without exposing hidden fields", %{
    conversation: conversation,
    event: event,
    offer: offer
  } do
    result =
      conversation
      |> progress("hi", "skip-email-1")
      |> progress("1", "skip-email-2")
      |> progress("1", "skip-email-3")
      |> progress("1", "skip-email-4")
      |> progress("1", "skip-email-5")
      |> progress("2", "skip-email-6")
      |> progress("Jan Burger", "skip-email-7")
      |> progress("1", "skip-email-8")

    assert result.conversation.state == "confirming_order"
    assert result.response_body =~ "Naam: Jan Burger"
    assert result.response_body =~ "E-pos: Nie verskaf nie"
    assert result.response_body =~ "Geleentheid: Voelgoed Live"
    assert result.response_body =~ "Kaartjie: General - R10"
    assert result.response_body =~ "Aantal: 2"
    assert result.response_body =~ "Totaal betaalbaar: R20"
    refute exposes_raw_id?(result.response_body, event.id)
    refute exposes_raw_id?(result.response_body, offer.id)
    refute result.response_body =~ "https://"
    refute result.response_body =~ "payment_url"
    refute result.response_body =~ "ticket_url"
    refute result.response_body =~ "access_code"
    refute result.response_body =~ "provider"
    refute result.response_body =~ "token"
  end

  test "ticket type menu renders prices for multiple active offers without exposing ids", %{
    conversation: conversation,
    offer: offer,
    event: event
  } do
    vip =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "VIP",
        price_cents: 199_950,
        max_per_order: 4
      )

    on_exit(fn -> SalesFixtures.flush_inventory_keys(vip.id) end)

    result =
      conversation
      |> progress("hi", "multi-1")
      |> progress("1", "multi-2")
      |> progress("1", "multi-3")
      |> progress("1", "multi-4")

    assert result.conversation.state == "selecting_ticket_type"
    assert result.response_body =~ ~r/\d+\. General - R10/
    assert result.response_body =~ ~r/\d+\. VIP - R1999\.50/
    assert result.response_body =~ "0. Terug"
    refute exposes_raw_id?(result.response_body, offer.id)
    refute exposes_raw_id?(result.response_body, vip.id)
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

  test "# restart clears current flow and returns to main menu", %{conversation: conversation} do
    result =
      conversation
      |> progress("hi", "restart-hash-1")
      |> progress("1", "restart-hash-2")
      |> progress("1", "restart-hash-3")
      |> progress("1", "restart-hash-4")
      |> progress("1", "restart-hash-5")
      |> progress("2", "restart-hash-6")
      |> progress("Jan Burger", "restart-hash-7")
      |> progress("jan@example.com", "restart-hash-8")

    assert result.conversation.state == "confirming_order"

    assert {:ok, restarted} = handle(result.conversation, "#", "wamid.restart-hash-9")

    assert restarted.conversation.state == "main_menu"
    assert restarted.response_body =~ "Koop kaartjies"
    assert_flow_fields_absent(restarted.conversation.state_data)
    refute_enqueued(worker: SendWhatsAppPaymentLinkWorker)
  end

  test "restart alias clears current flow and returns to main menu", %{conversation: conversation} do
    result =
      conversation
      |> progress("hi", "restart-alias-1")
      |> progress("1", "restart-alias-2")
      |> progress("1", "restart-alias-3")
      |> progress("1", "restart-alias-4")
      |> progress("1", "restart-alias-5")
      |> progress("2", "restart-alias-6")
      |> progress("Jan Burger", "restart-alias-7")

    assert result.conversation.state == "collecting_email"

    assert {:ok, restarted} = handle(result.conversation, "restart", "wamid.restart-alias-8")

    assert restarted.conversation.state == "main_menu"
    assert restarted.response_body =~ "Koop kaartjies"
    refute restarted.response_body =~ "restart"
    assert_flow_fields_absent(restarted.conversation.state_data)

    second_conversation = insert_conversation!()

    second_result =
      second_conversation
      |> progress("hi", "restart-uppercase-1")
      |> progress("1", "restart-uppercase-2")
      |> progress("1", "restart-uppercase-3")

    assert second_result.conversation.state == "selecting_event"

    assert {:ok, restarted_uppercase} =
             handle(second_result.conversation, " RESTART ", "wamid.restart-uppercase-4")

    assert restarted_uppercase.conversation.state == "main_menu"
    assert restarted_uppercase.response_body =~ "Koop kaartjies"
    refute restarted_uppercase.response_body =~ "restart"
  end

  test "0 from selecting_ticket_type returns to event selection", %{
    conversation: conversation,
    event: event
  } do
    result =
      conversation
      |> progress("hi", "back-event-1")
      |> progress("1", "back-event-2")
      |> progress("1", "back-event-3")
      |> progress("1", "back-event-4")

    assert result.conversation.state == "selecting_ticket_type"

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-event-5")

    assert backed.conversation.state == "selecting_event"
    assert backed.response_body =~ "Kies 'n geleentheid"
    assert backed.response_body =~ "Voelgoed Live"
    assert backed.conversation.state_data["event_options"] == %{"1" => event.id}
    refute Map.has_key?(backed.conversation.state_data, "selected_event_id")
    refute Map.has_key?(backed.conversation.state_data, "selected_offer_id")
  end

  test "0 from collecting_quantity returns to ticket type selection", %{
    conversation: conversation,
    event: event
  } do
    result =
      conversation
      |> progress("hi", "back-offer-1")
      |> progress("1", "back-offer-2")
      |> progress("1", "back-offer-3")
      |> progress("1", "back-offer-4")
      |> progress("1", "back-offer-5")

    assert result.conversation.state == "collecting_quantity"

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-offer-6")

    assert backed.conversation.state == "selecting_ticket_type"
    assert backed.response_body =~ "General - R10"
    assert backed.conversation.state_data["selected_event_id"] == event.id
    assert backed.conversation.state_data["offer_options"] != %{}
    refute Map.has_key?(backed.conversation.state_data, "selected_offer_id")
    refute Map.has_key?(backed.conversation.state_data, "quantity")
  end

  test "0 from collecting_buyer_name returns to quantity", %{
    conversation: conversation,
    event: event,
    offer: offer
  } do
    result =
      conversation
      |> progress("hi", "back-quantity-1")
      |> progress("1", "back-quantity-2")
      |> progress("1", "back-quantity-3")
      |> progress("1", "back-quantity-4")
      |> progress("1", "back-quantity-5")
      |> progress("2", "back-quantity-6")

    assert result.conversation.state == "collecting_buyer_name"

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-quantity-7")

    assert backed.conversation.state == "collecting_quantity"
    assert backed.response_body =~ "Hoeveel kaartjies"
    assert backed.conversation.state_data["selected_event_id"] == event.id
    assert backed.conversation.state_data["selected_offer_id"] == offer.id
    refute Map.has_key?(backed.conversation.state_data, "quantity")
    refute Map.has_key?(backed.conversation.state_data, "buyer_name")
    refute Map.has_key?(backed.conversation.state_data, "buyer_email")
  end

  test "0 from collecting_email returns to buyer name", %{
    conversation: conversation,
    event: event,
    offer: offer
  } do
    result =
      conversation
      |> progress("hi", "back-name-1")
      |> progress("1", "back-name-2")
      |> progress("1", "back-name-3")
      |> progress("1", "back-name-4")
      |> progress("1", "back-name-5")
      |> progress("2", "back-name-6")
      |> progress("Jan Burger", "back-name-7")

    assert result.conversation.state == "collecting_email"

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-name-8")

    assert backed.conversation.state == "collecting_buyer_name"
    assert backed.response_body =~ "Stuur asseblief jou naam"
    assert backed.conversation.state_data["selected_event_id"] == event.id
    assert backed.conversation.state_data["selected_offer_id"] == offer.id
    assert backed.conversation.state_data["quantity"] == 2
    refute Map.has_key?(backed.conversation.state_data, "buyer_name")
    refute Map.has_key?(backed.conversation.state_data, "buyer_email")
  end

  test "0 from confirming_order returns to email collection", %{conversation: conversation} do
    result =
      conversation
      |> progress("hi", "back-email-1")
      |> progress("1", "back-email-2")
      |> progress("1", "back-email-3")
      |> progress("1", "back-email-4")
      |> progress("1", "back-email-5")
      |> progress("2", "back-email-6")
      |> progress("Jan Burger", "back-email-7")
      |> progress("jan@example.com", "back-email-8")

    assert result.conversation.state == "confirming_order"

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-email-9")

    assert backed.conversation.state == "collecting_email"
    assert backed.response_body =~ "Stuur jou e-posadres"
    assert backed.conversation.state_data["buyer_name"] == "Jan Burger"
    refute Map.has_key?(backed.conversation.state_data, "buyer_email")
    refute Map.has_key?(backed.conversation.state_data, "sales_order_id")
    refute Map.has_key?(backed.conversation.state_data, "payment_attempt_id")
    refute Map.has_key?(backed.conversation.state_data, "order_public_reference")
    refute_enqueued(worker: SendWhatsAppPaymentLinkWorker)
  end

  test "0 from collecting_quantity falls back safely when refreshed offers disappear", %{
    conversation: conversation,
    offer: offer
  } do
    result =
      conversation
      |> progress("hi", "back-missing-offers-1")
      |> progress("1", "back-missing-offers-2")
      |> progress("1", "back-missing-offers-3")
      |> progress("1", "back-missing-offers-4")
      |> progress("1", "back-missing-offers-5")

    assert result.conversation.state == "collecting_quantity"

    Repo.query!("UPDATE sales_ticket_offers SET sales_enabled = false WHERE id = $1", [offer.id])

    assert {:ok, backed} = handle(result.conversation, "0", "wamid.back-missing-offers-6")

    assert backed.conversation.state in ["selecting_event", "main_menu"]
    refute Map.has_key?(backed.conversation.state_data, "selected_offer_id")
  end

  test "invalid input repeats current menu without advancing state", %{conversation: conversation} do
    assert {:ok, result} = handle(conversation, "hi", "wamid.invalid-1")
    assert {:ok, repeated} = handle(result.conversation, "ten", "wamid.invalid-2")

    assert repeated.conversation.state == "selecting_language"
    assert repeated.response_body =~ "Antwoord asseblief"
    assert repeated.response_body =~ "Welkom by FastCheck Tickets"
  end

  test "fresh checkpointed inbound message still produces first reply" do
    provider_message_id = "wamid.checkpointed-fresh"
    conversation = insert_conversation!(last_inbound_message_id: provider_message_id)

    assert {:ok, result} = handle(conversation, "hi", provider_message_id)

    assert result.send_reply?
    assert result.response_body =~ "Welkom by FastCheck Tickets"
    assert result.conversation.state == "selecting_language"

    assert result.conversation.state_data["last_handled_inbound_message_id"] ==
             provider_message_id
  end

  test "handled inbound message is suppressed when worker repeats same provider message id", %{
    conversation: conversation
  } do
    provider_message_id = "wamid.handled-duplicate"

    assert {:ok, first} = handle(conversation, "hi", provider_message_id)
    assert first.send_reply?
    assert first.conversation.state == "selecting_language"

    assert {:ok, duplicate} = handle(first.conversation, "hi", provider_message_id)

    refute duplicate.send_reply?
    assert duplicate.response_body == ""
    assert duplicate.conversation.state == "selecting_language"
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

  defp insert_conversation!(opts \\ []) do
    last_inbound_message_id = Keyword.get(opts, :last_inbound_message_id)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, last_inbound_message_id, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', 'new', '{}', $1, false, now(), now())
        RETURNING id
        """,
        [last_inbound_message_id]
      )

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

  defp exposes_raw_id?(body, id) do
    Regex.match?(~r/(?<![A-Za-z0-9])#{Regex.escape(to_string(id))}(?![A-Za-z0-9])/, body)
  end

  defp assert_flow_fields_absent(state_data) do
    for key <- [
          "selected_event_id",
          "selected_offer_id",
          "quantity",
          "buyer_name",
          "buyer_email",
          "sales_order_id",
          "payment_attempt_id",
          "order_public_reference"
        ] do
      refute Map.has_key?(state_data, key), "expected #{key} to be absent"
    end
  end

  defp assert_resend_fields_absent(state_data) do
    for key <- [
          "resend_name",
          "resend_email",
          "resend_requested_at",
          "resend_email_otp_result_status",
          "resend_correlation_id",
          "resend_challenge_public_id"
        ] do
      refute Map.has_key?(state_data, key), "expected #{key} to be absent"
    end
  end

  defp delivery_attempt_count do
    DeliveryAttempt
    |> Query.for_read(:read, %{})
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
