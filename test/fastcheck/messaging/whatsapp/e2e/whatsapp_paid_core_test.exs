defmodule FastCheck.Messaging.WhatsApp.E2E.WhatsAppPaidCoreTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  require Ash.Query

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Messaging.WhatsApp.PaymentFlow
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Conversation
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.IssueTicketsWorker
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker

  @moduletag :e2e
  @moduletag :sales
  @moduletag :payments
  @moduletag :whatsapp
  @moduletag :slow

  setup do
    whatsapp_cleanup = WebhookTestSupport.setup_whatsapp!()
    WebhookTestSupport.flush_redis_keys!()
    paystack_cleanup = PaystackSupport.setup_paystack!()
    {event, offer} = E2E.setup_sales_event_offer!(sales_channel: "whatsapp")

    on_exit(fn ->
      FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
      paystack_cleanup.()
      whatsapp_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "WhatsApp paid core creates checkout, sends payment link, verifies payment, and sends ticket link",
       %{event: event, offer: offer} do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => E2E.e2e_id("wamid")}]})
       }}
    end)

    conversation =
      insert_conversation!(
        state: "confirming_order",
        state_data: checkout_state_data(event, offer)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, PaystackSupport.success_request_fun())

    log =
      capture_log(fn ->
        assert {:ok, result} =
                 PaymentFlow.confirm_checkout_from_conversation(
                   command("wamid.vs22-pay"),
                   conversation
                 )

        refute result.response_body =~ "https://checkout.paystack.com"
        assert result.conversation.state == "payment_pending"

        order_id = result.conversation.state_data["sales_order_id"]
        attempt_id = result.conversation.state_data["payment_attempt_id"]

        assert_enqueued(
          worker: SendWhatsAppPaymentLinkWorker,
          args: %{
            "conversation_id" => conversation.id,
            "sales_order_id" => order_id,
            "payment_attempt_id" => attempt_id
          }
        )

        assert :ok =
                 perform_job(SendWhatsAppPaymentLinkWorker, %{
                   "conversation_id" => conversation.id,
                   "sales_order_id" => order_id,
                   "payment_attempt_id" => attempt_id
                 })

        assert_received {:whatsapp_request, payment_request}
        assert payment_request.options.json["type"] == "text"
        assert payment_request.options.json["text"]["body"] =~ "https://checkout.paystack.com"

        attempt = E2E.reload_payment_attempt!(attempt_id)

        Application.put_env(
          :fastcheck,
          :paystack_request_fun,
          PaystackSupport.init_and_verify_request_fun(
            amount: attempt.amount_cents,
            currency: attempt.currency
          )
        )

        assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

        assert :ok =
                 perform_job(IssueTicketsWorker, %{
                   "sales_order_id" => order_id,
                   "correlation_id" => E2E.e2e_id("issue-wa"),
                   "idempotency_key" => E2E.e2e_id("issue-wa")
                 })

        issue = E2E.ticket_issue_for_order!(order_id)
        conversation = reload_conversation!(conversation.id)

        assert {:ok, status_result} =
                 PaymentFlow.respond_to_status_request(command("wamid.vs22-ticket"), conversation)

        assert status_result.response_body =~ "veilige kaartjie-skakel"

        assert_enqueued(
          worker: SendWhatsAppTicketLinkWorker,
          args: %{
            "conversation_id" => conversation.id,
            "sales_order_id" => order_id,
            "ticket_issue_id" => issue.id
          }
        )

        assert :ok =
                 perform_job(SendWhatsAppTicketLinkWorker, %{
                   "conversation_id" => conversation.id,
                   "sales_order_id" => order_id,
                   "ticket_issue_id" => issue.id
                 })

        assert_received {:whatsapp_request, ticket_request}
        assert ticket_request.options.json["type"] == "text"
        assert ticket_request.options.json["text"]["body"] =~ "/t/"
        refute ticket_request.options.json["text"]["body"] =~ issue.delivery_token_hash

        assert ["sent", "sent"] =
                 Repo.all(
                   from d in "sales_delivery_attempts",
                     where: d.sales_order_id == ^order_id,
                     order_by: [asc: d.id],
                     select: d.status
                 )
      end)

    refute log =~ "+27821234567"
    refute log =~ "27821234567"
    refute log =~ "vs22-buyer@example.com"
    refute log =~ "https://checkout.paystack.com"
  end

  test "outside WhatsApp 24-hour window uses approved ticket template and outbound dedupe", %{
    event: event,
    offer: offer
  } do
    test_pid = self()

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => "wamid.template"}]})
       }}
    end)

    %{order: order, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      PaystackSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    assert :ok =
             perform_job(IssueTicketsWorker, %{
               "sales_order_id" => order.id,
               "correlation_id" => E2E.e2e_id("issue-wa-template"),
               "idempotency_key" => E2E.e2e_id("issue-wa-template")
             })

    issue = E2E.ticket_issue_for_order!(order.id)

    conversation =
      insert_conversation!(
        state: "ticket_issued",
        state_data: %{"sales_order_id" => order.id},
        preferred_language: "en",
        last_message_at: DateTime.utc_now() |> DateTime.add(-25, :hour)
      )

    args = %{
      "conversation_id" => conversation.id,
      "sales_order_id" => order.id,
      "ticket_issue_id" => issue.id
    }

    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)
    assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)

    assert_received {:whatsapp_request, request}
    refute_received {:whatsapp_request, _duplicate}
    assert request.options.json["type"] == "template"
    assert request.options.json["template"]["name"] == "fastcheck_ticket_ready_en"

    assert [%{status: "sent", within_whatsapp_window: false}] =
             Repo.all(
               from d in "sales_delivery_attempts",
                 where: d.ticket_issue_id == ^issue.id,
                 select: map(d, [:status, :within_whatsapp_window])
             )
  end

  defp checkout_state_data(event, offer) do
    %{
      "selected_event_id" => event.id,
      "selected_event_label" => event.name,
      "selected_offer_id" => offer.id,
      "selected_offer_label" => offer.name,
      "quantity" => 1,
      "buyer_name" => "VS-22 Buyer",
      "buyer_email" => "vs22-buyer@example.com"
    }
  end

  defp insert_conversation!(opts) do
    state = Keyword.fetch!(opts, :state)
    state_data = Keyword.fetch!(opts, :state_data)
    preferred_language = Keyword.get(opts, :preferred_language, "af")
    last_message_at = Keyword.get(opts, :last_message_at, DateTime.utc_now())

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, last_message_at, needs_human, inserted_at, updated_at)
        VALUES
          ('+27821234567', '27821234567', $1, $2, $3, $4, false, now(), now())
        RETURNING id
        """,
        [preferred_language, state, state_data, last_message_at]
      )

    reload_conversation!(id)
  end

  defp reload_conversation!(id) do
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
end
