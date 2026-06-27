defmodule FastCheck.Sales.E2E.RevocationScannerVisibilityTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures
  alias FastCheck.Sales.AdminRevocations
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.IssueTicketsWorker

  @moduletag :e2e
  @moduletag :sales
  @moduletag :scanner_visibility
  @moduletag :slow

  setup do
    paystack_cleanup = PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    scan_cleanup = E2E.configure_mobile_scan_ingestion!()
    {event, offer} = E2E.setup_sales_event_offer!(sales_channel: "whatsapp")

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: AdminRefundFixtures.dashboard_password()
    })

    on_exit(fn ->
      FastCheck.SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      PaystackSupport.flush_webhook_dedupe_keys!()
      scan_cleanup.()
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "admin revocation removes secure ticket validity and scanner/mobile visibility", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer, source_channel: "whatsapp")

    %{event: payment_event} = E2E.ingest_paystack_success!(attempt)

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

    issue = E2E.ticket_issue_for_order!(order.id)
    version_before = E2E.event_sync_version(event.id)

    token = FastCheck.Tickets.DeliveryToken.generate().token
    hash = FastCheck.Tickets.TokenHash.hash(token, :delivery)

    Repo.update_all(
      from(t in "sales_ticket_issues", where: t.id == ^issue.id),
      set: [
        delivery_token_hash: hash,
        delivery_token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      ]
    )

    assert conn |> get(~p"/t/#{token}") |> html_response(200) =~ issue.ticket_code

    assert {:ok, %{status: :revoked}} =
             AdminRevocations.revoke_ticket_issue(
               AdminRefundFixtures.admin_actor(event_id: event.id),
               issue.id,
               AdminRefundFixtures.admin_attrs(%{
                 "reason" => "Customer requested refund",
                 "confirmed_bulk" => nil,
                 "admin_password" => nil
               })
             )

    revoked_issue = E2E.reload_ticket_issue!(issue.id)
    assert revoked_issue.status == "revoked"
    assert E2E.event_sync_version(event.id) == version_before + 1

    assert Repo.aggregate(
             from(i in AttendeeInvalidationEvent, where: i.attendee_id == ^issue.attendee_id),
             :count
           ) == 1

    refute conn |> recycle() |> get(~p"/t/#{token}") |> html_response(200) =~ issue.ticket_code

    mobile_token = E2E.mobile_token!(event.id)

    scan_conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{mobile_token}")
      |> post(~p"/api/v1/mobile/scans", %{
        "scans" => [E2E.scan_payload(issue.ticket_code)]
      })

    assert %{
             "data" => %{
               "results" => [
                 %{
                   "status" => "error",
                   "message" => "This ticket is no longer valid for scanning"
                 }
               ]
             },
             "error" => nil
           } = json_response(scan_conn, 200)
  end

  test "admin destructive revocation requires an explicit reason", %{event: event, offer: offer} do
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

    assert {:ok, :verified} =
             FastCheck.Sales.Payments.PaymentVerification.verify_attempt(attempt.id)

    assert :ok =
             perform_job(IssueTicketsWorker, %{
               "sales_order_id" => order.id,
               "correlation_id" => E2E.e2e_id("issue"),
               "idempotency_key" => E2E.e2e_id("issue")
             })

    issue = E2E.ticket_issue_for_order!(order.id)

    assert {:error, :reason_required} =
             AdminRevocations.revoke_ticket_issue(
               AdminRefundFixtures.admin_actor(event_id: event.id),
               issue.id,
               %{"reason" => "  "}
             )
  end
end
