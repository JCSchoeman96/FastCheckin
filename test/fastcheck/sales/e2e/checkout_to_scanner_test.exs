defmodule FastCheck.Sales.E2E.CheckoutToScannerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.Workers.IssueTicketsWorker

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

        assert :ok =
                 perform_job(IssueTicketsWorker, %{
                   "sales_order_id" => order.id,
                   "correlation_id" => E2E.e2e_id("issue"),
                   "idempotency_key" => E2E.e2e_id("issue")
                 })

        order = E2E.reload_order!(order.id)
        session = E2E.reload_session!(session.id)
        attempt = E2E.reload_payment_attempt!(attempt.id)
        issue = E2E.ticket_issue_for_order!(order.id)

        assert order.status == "ticket_issued"
        assert session.status == "paid"
        assert attempt.status == "verified_success"

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

  test "duplicate webhook and duplicate workers do not duplicate payment, tickets, attendees, or inventory",
       %{event: event, offer: offer} do
    %{order: order, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp", quantity: 2)

    webhook = E2E.ingest_paystack_success!(attempt, provider_event_id: "evt-vs22-duplicate")
    duplicate = FastCheck.Sales.Payments.WebhookIngestion.ingest(webhook.body, webhook.signature)

    assert {:ok, :duplicate, duplicate_event} = duplicate
    assert duplicate_event.id == webhook.event.id

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => webhook.event.id})
    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => webhook.event.id})

    assert :ok =
             perform_job(VerifyPaymentWorker, %{
               "payment_event_id" => webhook.event.id,
               "payment_attempt_id" => attempt.id
             })

    assert :ok =
             perform_job(VerifyPaymentWorker, %{
               "payment_event_id" => webhook.event.id,
               "payment_attempt_id" => attempt.id
             })

    issue_args = %{
      "sales_order_id" => order.id,
      "correlation_id" => E2E.e2e_id("issue"),
      "idempotency_key" => "issue-#{order.id}"
    }

    assert :ok = perform_job(IssueTicketsWorker, issue_args)
    assert :ok = perform_job(IssueTicketsWorker, issue_args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "ticket_issued"

    assert E2E.sales_counts(order.id) == %{
             attendees: 2,
             ticket_issues: 2,
             issued_ticket_issues: 2
           }

    assert E2E.order_transition_count(order.id, "ticket_issued") == 1
    assert E2E.inventory_snapshot!(offer.id).reserved_quantity == 2
  end
end
