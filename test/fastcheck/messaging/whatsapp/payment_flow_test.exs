defmodule FastCheck.Messaging.WhatsApp.PaymentFlowTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias Ash.Changeset
  alias FastCheck.Fixtures
  import Ecto.Query

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.PaymentFlow
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Payments.TestSupport, as: PaymentSupport
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheck.Tickets.{DeliveryToken, TokenHash}
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheckWeb.SalesWebFixtures

  setup do
    WebhookTestSupport.flush_redis_keys!()
    paystack_cleanup = PaymentSupport.setup_paystack!()

    event =
      SalesWebFixtures.insert_event!(%{
        name: "VS-19 Event",
        scanner_login_code: scanner_code()
      })

    offer = SalesFixtures.insert_offer!(event_id: event.id, name: "VS-19 General")

    on_exit(fn ->
      SalesFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "confirming order with buyer email initializes Paystack and queues payment-link send", %{
    event: event,
    offer: offer
  } do
    conversation =
      insert_conversation!(
        state: "confirming_order",
        state_data: checkout_state_data(event, offer, "buyer@example.com")
      )

    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    assert {:ok, result} =
             PaymentFlow.confirm_checkout_from_conversation(command("wamid.pay-1"), conversation)

    assert result.conversation.state == "payment_pending"
    assert result.response_body =~ "betaling"
    refute result.response_body =~ "https://checkout.paystack.com"

    order_id = result.conversation.state_data["sales_order_id"]
    assert is_integer(order_id)
    assert is_binary(result.conversation.state_data["order_public_reference"])
    assert is_integer(result.conversation.state_data["payment_attempt_id"])

    assert 1 =
             Repo.all(
               from p in "sales_payment_attempts",
                 where: p.sales_order_id == ^order_id,
                 select: p.id
             )
             |> length()

    assert_enqueued(
      worker: SendWhatsAppPaymentLinkWorker,
      args: %{
        "conversation_id" => conversation.id,
        "sales_order_id" => order_id,
        "payment_attempt_id" => result.conversation.state_data["payment_attempt_id"]
      }
    )
  end

  test "missing buyer email asks for email before Paystack initialization", %{
    event: event,
    offer: offer
  } do
    conversation =
      insert_conversation!(
        state: "confirming_order",
        state_data: checkout_state_data(event, offer, nil)
      )

    {request_fun, counter} = PaymentSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:ok, result} =
             PaymentFlow.confirm_checkout_from_conversation(
               command("wamid.email-1"),
               conversation
             )

    assert result.conversation.state == "collecting_email"
    assert result.response_body =~ "e-pos"
    assert :counters.get(counter, 1) == 0
    refute_enqueued(worker: SendWhatsAppPaymentLinkWorker)
  end

  test "awaiting_payment status reuses existing order and checkout session", %{
    event: event,
    offer: offer
  } do
    {:ok, %{order: order}} =
      Checkout.start_checkout(
        %{
          event_id: event.id,
          ticket_offer_id: offer.id,
          quantity: 1,
          buyer_name: "Jan Burger",
          buyer_phone: "+27821234567",
          buyer_email: "buyer@example.com",
          source_channel: "whatsapp",
          idempotency_key: "status-#{System.unique_integer([:positive])}",
          correlation_id: "corr-status",
          event_name: event.name
        },
        %{actor_type: :customer_session, actor_id: "customer-1", allowed_event_ids: [event.id]}
      )

    conversation =
      insert_conversation!(
        state: "awaiting_payment",
        state_data: %{
          "sales_order_id" => order.id,
          "order_public_reference" => order.public_reference
        }
      )

    before_count = Repo.one!(from o in "sales_orders", select: count(o.id))
    Application.put_env(:fastcheck, :paystack_request_fun, PaymentSupport.success_request_fun())

    assert {:ok, result} =
             PaymentFlow.respond_to_status_request(command("wamid.status-1"), conversation)

    after_count = Repo.one!(from o in "sales_orders", select: count(o.id))
    assert before_count == after_count
    assert result.conversation.state == "payment_pending"
    assert result.conversation.state_data["sales_order_id"] == order.id

    assert_enqueued(worker: SendWhatsAppPaymentLinkWorker)
  end

  test "ticket_issued status says secure ticket link is being sent", %{event: event} do
    %{order_id: order_id, ticket_issue_id: ticket_issue_id} = issued_ticket_fixture(event)

    conversation =
      insert_conversation!(
        state: "ticket_issued",
        state_data: %{"sales_order_id" => order_id}
      )

    assert {:ok, result} =
             PaymentFlow.respond_to_status_request(command("wamid.ticket-ready"), conversation)

    assert result.response_body =~ "veilige kaartjie-skakel"
    assert result.response_body =~ "stuur"
    refute result.response_body =~ "nog nie gereed"

    assert_enqueued(
      worker: SendWhatsAppTicketLinkWorker,
      args: %{
        "conversation_id" => conversation.id,
        "sales_order_id" => order_id,
        "ticket_issue_id" => ticket_issue_id
      }
    )
  end

  defp checkout_state_data(event, offer, buyer_email) do
    %{
      "selected_event_id" => event.id,
      "selected_event_label" => event.name,
      "selected_offer_id" => offer.id,
      "selected_offer_label" => offer.name,
      "quantity" => 1,
      "buyer_name" => "Jan Burger",
      "buyer_email" => buyer_email
    }
  end

  defp insert_conversation!(opts) do
    state = Keyword.fetch!(opts, :state)
    state_data = Keyword.fetch!(opts, :state_data)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', 'af', $1, $2, false, now(), now())
        RETURNING id
        """,
        [state, state_data]
      )

    Conversation
    |> Ash.Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp issued_ticket_fixture(event) do
    attendee = Fixtures.create_attendee(event, %{payment_status: "completed"})
    token = DeliveryToken.generate(ttl_seconds: 3600)
    {order_id, order_line_id} = insert_order_with_line!(event.id)

    attrs = %{
      sales_order_id: order_id,
      sales_order_line_id: order_line_id,
      line_item_sequence: 1,
      attendee_id: attendee.id,
      ticket_code: attendee.ticket_code,
      qr_token_hash: TokenHash.hash("qr-#{System.unique_integer([:positive])}", :qr),
      delivery_token_hash: token.hash,
      delivery_token_expires_at: token.expires_at
    }

    assert {:ok, issue} =
             TicketIssue
             |> Changeset.for_create(:create_issued_link, attrs, actor: system_actor())
             |> Ash.create(authorize?: false)

    %{order_id: order_id, ticket_issue_id: issue.id}
  end

  defp insert_order_with_line!(event_id) do
    %{rows: [[offer_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, lock_version, inserted_at, updated_at)
        VALUES
          ($1, 'GA', 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp', 1, now(), now())
        RETURNING id
        """,
        [event_id]
      )

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, ticket_issued_at, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', '+27821234567', 'buyer@example.com', 'whatsapp',
           'ticket_issued', 100, 'ZAR', now(), now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}", event_id]
      )

    %{rows: [[line_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'GA', 'Event', 1, 100, 100, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id]
      )

    {order_id, line_id}
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "vs-19-payment-flow-test"}

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
