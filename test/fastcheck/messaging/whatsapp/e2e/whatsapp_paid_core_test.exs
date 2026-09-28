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
  alias FastCheck.Sales.TicketPage
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Tickets.TokenHash
  alias FastCheck.Workers.IssueTicketsWorker
  alias FastCheck.Workers.PaidOrderFulfillmentWorker
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheck.Workers.TicketDeliveryCoordinatorWorker

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

  test "quantity four flows through verified payment, issuance, and automatic ticket delivery",
       %{event: event, offer: offer} do
    test_pid = self()
    wamid_counter = :counters.new(1, [])

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn request ->
      send(test_pid, {:whatsapp_request, request})
      :counters.add(wamid_counter, 1, 1)

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "messages" => [%{"id" => "wamid.p0c-#{:counters.get(wamid_counter, 1)}"}]
           })
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

        assert_enqueued(
          worker: PaidOrderFulfillmentWorker,
          args: %{"payment_attempt_id" => attempt.id}
        )

        assert :ok =
                 perform_job(PaidOrderFulfillmentWorker, %{
                   "payment_attempt_id" => attempt.id
                 })

        assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order_id})
        assert [%{args: issuer_args}] = all_enqueued(worker: IssueTicketsWorker)
        assert :ok = perform_job(IssueTicketsWorker, issuer_args)

        assert_enqueued(
          worker: TicketDeliveryCoordinatorWorker,
          args: %{"sales_order_id" => order_id}
        )

        assert :ok =
                 perform_job(TicketDeliveryCoordinatorWorker, %{"sales_order_id" => order_id})

        send_jobs = all_enqueued(worker: SendWhatsAppTicketLinkWorker)
        assert length(send_jobs) == 4
        assert Enum.all?(send_jobs, &(Map.keys(&1.args) == ["ticket_delivery_intent_id"]))

        assert %FastCheck.Sales.Order{status: "ticket_issued"} = E2E.reload_order!(order_id)

        issues = E2E.ticket_issues_for_order(order_id)
        assert length(issues) == 4
        assert length(Enum.uniq(Enum.map(issues, & &1.id))) == 4

        assert Repo.one!(
                 from a in "attendees",
                   where: a.sales_order_id == ^order_id,
                   select: count(a.id)
               ) == 4

        assert Repo.one!(
                 from i in "sales_ticket_delivery_intents",
                   where:
                     i.sales_order_id == ^order_id and
                       i.purpose == "initial_ticket_delivery",
                   select: count(i.id)
               ) == 4

        delivered_issue_ids =
          Enum.map(send_jobs, fn %{args: args} = _job ->
            assert :ok =
                     perform_job(SendWhatsAppTicketLinkWorker, %{
                       "ticket_delivery_intent_id" => args["ticket_delivery_intent_id"]
                     })

            assert_received {:whatsapp_request, ticket_request}
            assert ticket_request.options.json["type"] == "text"
            body = ticket_request.options.json["text"]["body"]
            assert body =~ "/t/"
            token = extract_ticket_link_token!(body)

            current_issues = Enum.map(issues, &E2E.reload_ticket_issue!(&1.id))

            matches =
              Enum.filter(
                current_issues,
                &TokenHash.verify(token, &1.delivery_token_hash, :delivery)
              )

            assert [matching_issue] = matches
            assert TicketPage.resolve(token).state == :valid
            matching_issue.id
          end)

        assert length(Enum.uniq(delivered_issue_ids)) == 4

        intents =
          Repo.all(
            from i in "sales_ticket_delivery_intents",
              where: i.sales_order_id == ^order_id and i.purpose == "initial_ticket_delivery",
              select: map(i, [:status, :ticket_issue_id])
          )

        assert length(intents) == 4
        assert Enum.all?(intents, &(&1.status == "provider_accepted"))

        assert Enum.sort(Enum.map(intents, & &1.ticket_issue_id)) ==
                 Enum.sort(delivered_issue_ids)

        accepted_attempts =
          Repo.all(
            from d in "sales_delivery_attempts",
              where:
                d.sales_order_id == ^order_id and d.delivery_reason == "initial_ticket_delivery",
              select: map(d, [:status, :provider_message_id, :ticket_issue_id])
          )

        assert length(accepted_attempts) == 4
        assert Enum.all?(accepted_attempts, &(&1.status == "provider_accepted"))
        assert length(Enum.uniq(Enum.map(accepted_attempts, & &1.provider_message_id))) == 4
        assert length(Enum.uniq(Enum.map(accepted_attempts, & &1.ticket_issue_id))) == 4

        assert %{reserved_quantity: 0, consumed_quantity: 4} =
                 E2E.inventory_snapshot!(offer.id)
      end)

    refute log =~ "+27821234567"
    refute log =~ "27821234567"
    refute log =~ "vs22-buyer@example.com"
    refute log =~ "https://checkout.paystack.com"
  end

  test "automatic delivery uses the approved ticket template outside the 24-hour window", %{
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

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )

    assert :ok =
             perform_job(PaidOrderFulfillmentWorker, %{
               "payment_attempt_id" => attempt.id
             })

    assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
    assert [%{args: issuer_args}] = all_enqueued(worker: IssueTicketsWorker)
    assert :ok = perform_job(IssueTicketsWorker, issuer_args)

    issue = E2E.ticket_issue_for_order!(order.id)

    bound_order = E2E.reload_order!(order.id)

    Repo.update_all(
      from(c in "sales_conversations", where: c.id == ^bound_order.sales_conversation_id),
      set: [last_message_at: DateTime.utc_now() |> DateTime.add(-25, :hour)]
    )

    assert_enqueued(
      worker: TicketDeliveryCoordinatorWorker,
      args: %{"sales_order_id" => order.id}
    )

    assert :ok = perform_job(TicketDeliveryCoordinatorWorker, %{"sales_order_id" => order.id})

    assert [%{args: %{"ticket_delivery_intent_id" => intent_id}}] =
             all_enqueued(worker: SendWhatsAppTicketLinkWorker)

    assert :ok =
             perform_job(SendWhatsAppTicketLinkWorker, %{"ticket_delivery_intent_id" => intent_id})

    assert_received {:whatsapp_request, request}
    refute_received {:whatsapp_request, _duplicate}
    assert request.options.json["type"] == "template"
    assert request.options.json["template"]["name"] == "fastcheck_ticket_ready_en"

    assert [%{status: "provider_accepted", within_whatsapp_window: false}] =
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
      "selected_offer_lock_version" => offer.lock_version,
      "quantity" => 4,
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

  defp extract_ticket_link_token!(body) do
    case Regex.run(~r{/t/([^[:space:]]+)}, body) do
      [_, token] -> token
      _ -> flunk("expected a secure ticket link in the WhatsApp response")
    end
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
