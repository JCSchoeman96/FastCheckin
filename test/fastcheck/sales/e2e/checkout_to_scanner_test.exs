defmodule FastCheck.Sales.E2E.CheckoutToScannerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.Workers.IssueTicketsWorker
  alias FastCheck.Workers.PaidOrderFulfillmentWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheck.Workers.TicketDeliveryCoordinatorWorker

  @moduletag :e2e
  @moduletag :sales
  @moduletag :payments
  @moduletag :ticketing
  @moduletag :scanner_visibility
  @moduletag :slow

  setup do
    paystack_cleanup = PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    scan_cleanup = E2E.configure_mobile_scan_ingestion!()
    {event, offer} = E2E.setup_sales_event_offer!(sales_channel: "whatsapp")

    on_exit(fn ->
      FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      PaystackSupport.flush_webhook_dedupe_keys!()
      scan_cleanup.()
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "paid WhatsApp checkout issues one ticket and scanner accepts it", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    log =
      capture_log(fn ->
        %{order: order, session: session, attempt: attempt} =
          E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

        assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 1

        %{status: :created, event: payment_event} = E2E.ingest_paystack_success!(attempt)

        assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

        assert :ok =
                 perform_job(VerifyPaymentWorker, %{
                   "payment_event_id" => payment_event.id,
                   "payment_attempt_id" => attempt.id
                 })

        assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
        assert E2E.reload_order!(order.id).status == "paid_verified"

        assert_enqueued(
          worker: PaidOrderFulfillmentWorker,
          args: %{"payment_attempt_id" => attempt.id}
        )

        assert :ok =
                 perform_job(PaidOrderFulfillmentWorker, %{
                   "payment_attempt_id" => attempt.id
                 })

        assert E2E.reload_order!(order.id).status == "fulfillment_queued"
        assert %{reserved_quantity: 0, consumed_quantity: 1} = E2E.inventory_snapshot!(offer.id)
        assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
        assert [%{args: issuer_args}] = all_enqueued(worker: IssueTicketsWorker)
        assert :ok = perform_job(IssueTicketsWorker, issuer_args)

        order = E2E.reload_order!(order.id)
        session = E2E.reload_session!(session.id)
        attempt = E2E.reload_payment_attempt!(attempt.id)
        issue = E2E.ticket_issue_for_order!(order.id)

        assert order.status == "ticket_issued"
        assert session.status == "paid"
        assert attempt.status == "verified_success"
        assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 0
        assert E2E.inventory_snapshot!(offer.id).consumed_quantity == 1

        assert E2E.sales_counts(order.id) == %{
                 attendees: 1,
                 ticket_issues: 1,
                 issued_ticket_issues: 1
               }

        token = FastCheck.Tickets.DeliveryToken.generate().token
        hashed = FastCheck.Tickets.TokenHash.hash(token, :delivery)

        FastCheck.Repo.update_all(
          from(t in "sales_ticket_issues", where: t.id == ^issue.id),
          set: [
            delivery_token_hash: hashed,
            delivery_token_expires_at:
              DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
          ]
        )

        html = conn |> get(~p"/t/#{token}") |> html_response(200)
        assert html =~ issue.ticket_code
        refute html =~ hashed

        mobile_token = E2E.mobile_token!(event.id)

        sync_conn =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer #{mobile_token}")
          |> get(~p"/api/v1/mobile/attendees?limit=50")

        attendee_codes =
          sync_conn
          |> json_response(200)
          |> get_in(["data", "attendees"])
          |> Enum.map(& &1["ticket_code"])

        assert issue.ticket_code in attendee_codes

        scan_conn =
          conn
          |> recycle()
          |> put_req_header("authorization", "Bearer #{mobile_token}")
          |> post(~p"/api/v1/mobile/scans", %{
            "scans" => [E2E.scan_payload(issue.ticket_code)]
          })

        assert %{
                 "data" => %{
                   "processed" => 1,
                   "results" => [
                     %{"status" => "success", "message" => "Check-in successful"}
                   ]
                 },
                 "error" => nil
               } = json_response(scan_conn, 200)

        assert [%{args: args}] = all_enqueued(worker: PersistScanBatchJob)
        assert :ok = perform_job(PersistScanBatchJob, args)
      end)

    refute log =~ "vs22-buyer@example.com"
    refute log =~ "+27821234567"
    refute log =~ "https://checkout.paystack.com"
    refute log =~ "AC_SAFE"
  end

  test "duplicate payment and delivery workers produce four tickets and four customer sends",
       %{event: event, offer: offer} do
    whatsapp_cleanup = WebhookTestSupport.setup_whatsapp!()
    WebhookTestSupport.flush_redis_keys!()
    test_pid = self()
    provider_counter = :counters.new(1, [])

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _request ->
      :counters.add(provider_counter, 1, 1)
      provider_message_id = "wamid.duplicate-e2e-#{:counters.get(provider_counter, 1)}"
      send(test_pid, {:whatsapp_provider_acceptance, provider_message_id})

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{"messages" => [%{"id" => provider_message_id}]})
       }}
    end)

    on_exit(whatsapp_cleanup)

    %{order: order, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp", quantity: 4)

    webhook = E2E.ingest_paystack_success!(attempt, provider_event_id: "evt-vs22-duplicate")
    duplicate = FastCheck.Sales.Payments.WebhookIngestion.ingest(webhook.body, webhook.signature)

    assert {:ok, :duplicate, duplicate_event} = duplicate
    assert duplicate_event.id == webhook.event.id

    assert [%{args: webhook_args}] = all_enqueued(worker: PaystackWebhookWorker)
    assert :ok = perform_job(PaystackWebhookWorker, webhook_args)
    assert :ok = perform_job(PaystackWebhookWorker, webhook_args)

    assert [%{args: verification_args}] = all_enqueued(worker: VerifyPaymentWorker)

    assert :ok = perform_job(VerifyPaymentWorker, verification_args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"

    assert :ok = perform_job(VerifyPaymentWorker, verification_args)

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )

    assert [%{args: fulfillment_args}] = all_enqueued(worker: PaidOrderFulfillmentWorker)
    assert :ok = perform_job(PaidOrderFulfillmentWorker, fulfillment_args)
    assert :ok = perform_job(PaidOrderFulfillmentWorker, fulfillment_args)

    assert E2E.reload_order!(order.id).status == "fulfillment_queued"
    assert %{reserved_quantity: 0, consumed_quantity: 4} = E2E.inventory_snapshot!(offer.id)
    assert_enqueued(worker: IssueTicketsWorker, args: %{"sales_order_id" => order.id})
    assert [%{args: issue_args}] = all_enqueued(worker: IssueTicketsWorker)

    assert :ok = perform_job(IssueTicketsWorker, issue_args)
    assert :ok = perform_job(IssueTicketsWorker, issue_args)

    assert_enqueued(
      worker: TicketDeliveryCoordinatorWorker,
      args: %{"sales_order_id" => order.id}
    )

    assert [%{args: coordinator_args}] =
             all_enqueued(
               worker: TicketDeliveryCoordinatorWorker,
               args: %{"sales_order_id" => order.id}
             )

    assert :ok = perform_job(TicketDeliveryCoordinatorWorker, coordinator_args)
    assert :ok = perform_job(TicketDeliveryCoordinatorWorker, coordinator_args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "ticket_issued"

    assert E2E.sales_counts(order.id) == %{
             attendees: 4,
             ticket_issues: 4,
             issued_ticket_issues: 4
           }

    assert E2E.order_transition_count(order.id, "ticket_issued") == 1
    assert %{reserved_quantity: 0, consumed_quantity: 4} = E2E.inventory_snapshot!(offer.id)

    intents =
      Repo.all(
        from i in "sales_ticket_delivery_intents",
          where: i.sales_order_id == ^order.id and i.purpose == "initial_ticket_delivery",
          select: map(i, [:id, :ticket_issue_id, :status])
      )

    assert length(intents) == 4
    assert length(Enum.uniq(Enum.map(intents, & &1.ticket_issue_id))) == 4

    send_jobs = all_enqueued(worker: SendWhatsAppTicketLinkWorker)
    assert length(send_jobs) == 4

    Enum.each(send_jobs, fn %{args: %{"ticket_delivery_intent_id" => intent_id}} ->
      args = %{"ticket_delivery_intent_id" => intent_id}
      assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)
      assert :ok = perform_job(SendWhatsAppTicketLinkWorker, args)
      assert_received {:whatsapp_provider_acceptance, _provider_message_id}
      refute_received {:whatsapp_provider_acceptance, _duplicate_provider_message_id}
    end)

    accepted_attempts =
      Repo.all(
        from d in "sales_delivery_attempts",
          where: d.sales_order_id == ^order.id and d.delivery_reason == "initial_ticket_delivery",
          select: map(d, [:ticket_issue_id, :provider_message_id, :status])
      )

    assert length(accepted_attempts) == 4
    assert Enum.all?(accepted_attempts, &(&1.status == "provider_accepted"))
    assert length(Enum.uniq(Enum.map(accepted_attempts, & &1.ticket_issue_id))) == 4
    assert length(Enum.uniq(Enum.map(accepted_attempts, & &1.provider_message_id))) == 4

    assert 4 ==
             Repo.one!(
               from i in "sales_ticket_delivery_intents",
                 where:
                   i.sales_order_id == ^order.id and
                     i.purpose == "initial_ticket_delivery" and i.status == "provider_accepted",
                 select: count(i.id)
             )
  end
end
