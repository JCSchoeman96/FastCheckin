defmodule FastCheckWeb.Sales.PaystackCallbackControllerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Payments.{
    PaystackWebhookWorker,
    TestSupport,
    VerifyPaymentWorker,
    WebhookIngestion
  }

  alias FastCheck.Repo
  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.{IssueTicketsWorker, PaidOrderFulfillmentWorker}

  @callback_path "/sales/payments/paystack/callback"

  setup do
    original_request_fun = Application.get_env(:fastcheck, :paystack_request_fun)
    paystack_cleanup = TestSupport.setup_paystack!()
    TestSupport.flush_webhook_dedupe_keys!()
    {event, offer} = E2E.setup_sales_event_offer!()

    on_exit(fn ->
      SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      TestSupport.flush_webhook_dedupe_keys!()
      paystack_cleanup.()

      if is_nil(original_request_fun),
        do: Application.delete_env(:fastcheck, :paystack_request_fun),
        else: Application.put_env(:fastcheck, :paystack_request_fun, original_request_fun)
    end)

    {:ok, event: event, offer: offer}
  end

  test "callback route suppresses dispatch logging of query parameters" do
    route =
      Enum.find(FastCheckWeb.Router.__routes__(), &(&1.path == @callback_path))

    assert %{
             verb: :get,
             metadata: %{log: false},
             plug: FastCheckWeb.Sales.PaystackCallbackController
           } =
             route
  end

  test "callback reference queues verification and status=success is not payment authority", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn =
      get(conn, @callback_path, %{
        "reference" => attempt.provider_reference,
        "status" => "success",
        "amount" => "1",
        "currency" => "USD",
        "email" => "attacker@example.test"
      })

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    assert conn.resp_body =~ "You can return to WhatsApp."

    assert conn.resp_body =~
             "If Paystack confirms the payment, your ticket will be processed automatically."

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert [_csp] = get_resp_header(conn, "content-security-policy")

    page_and_headers =
      conn.resp_body <>
        Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)

    refute page_and_headers =~ attempt.provider_reference
    refute page_and_headers =~ order.public_reference
    refute page_and_headers =~ order.buyer_email
    refute page_and_headers =~ order.buyer_phone
    refute page_and_headers =~ Integer.to_string(order.total_amount_cents)
    refute page_and_headers =~ "attacker@example.test"

    assert E2E.reload_payment_attempt!(attempt.id).status == "initialized"
    refute E2E.reload_order!(order.id).status == "paid_verified"
    assert :counters.get(request_count, 1) == 0
    assert_enqueued(worker: VerifyPaymentWorker, args: %{"payment_attempt_id" => attempt.id})
  end

  test "successful callback handoff uses the normal server-side verification lifecycle", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn =
      get(build_conn(), @callback_path, %{
        "reference" => attempt.provider_reference,
        "trxref" => attempt.provider_reference
      })

    assert conn.status == 200
    assert :counters.get(request_count, 1) == 0

    assert [%{args: args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert args == %{"payment_attempt_id" => attempt.id}
    assert :ok = perform_job(VerifyPaymentWorker, args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )
  end

  test "invalid and unknown references share a safe response and create no payment work", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    inputs = [
      %{"status" => "success"},
      %{"reference" => ""},
      %{"reference" => String.duplicate("a", 101)},
      %{"reference" => "unsupported*value"},
      %{"reference" => attempt.provider_reference, "trxref" => "different-reference"},
      %{"reference" => "valid-but-unknown-reference"}
    ]

    responses =
      Enum.map(inputs, fn params ->
        conn = get(build_conn(), @callback_path, params)
        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
        assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
        conn
      end)

    assert Enum.map(responses, & &1.resp_body) |> Enum.uniq() |> length() == 1

    page_and_headers =
      Enum.map_join(responses, "\n", fn conn ->
        conn.resp_body <>
          Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)
      end)

    refute page_and_headers =~ attempt.provider_reference
    refute page_and_headers =~ order.public_reference
    refute page_and_headers =~ order.buyer_email
    refute page_and_headers =~ order.buyer_phone
    assert E2E.reload_payment_attempt!(attempt.id).status == "initialized"
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 0
  end

  test "known terminal references receive the safe page without re-verification", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!("UPDATE sales_payment_attempts SET status = 'manual_review' WHERE id = $1", [
      attempt.id
    ])

    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    refute conn.resp_body =~ attempt.provider_reference
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 0
    assert E2E.reload_payment_attempt!(attempt.id).status == "manual_review"
  end

  test "callback and webhook races produce one verified payment and one fulfillment chain", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    body =
      TestSupport.charge_success_webhook_body(
        reference: attempt.provider_reference,
        provider_event_id: "evt-callback-race-#{System.unique_integer([:positive])}"
      )

    signature = TestSupport.sign_webhook_body(body)

    callback_task =
      Task.async(fn ->
        get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})
      end)

    webhook_task = Task.async(fn -> WebhookIngestion.ingest(body, signature) end)

    assert %{status: 200} = Task.await(callback_task)
    assert {:ok, :created, payment_event} = Task.await(webhook_task)

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    assert [%{args: verify_args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert verify_args["payment_attempt_id"] == attempt.id
    assert :ok = perform_job(VerifyPaymentWorker, verify_args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert E2E.order_transition_count(order.id, "paid_verified") == 1
    assert length(all_enqueued(worker: PaidOrderFulfillmentWorker)) == 1

    assert [%{args: fulfillment_args}] = all_enqueued(worker: PaidOrderFulfillmentWorker)
    assert :ok = perform_job(PaidOrderFulfillmentWorker, fulfillment_args)
    assert %{reserved_quantity: 0, consumed_quantity: 1} = E2E.inventory_snapshot!(offer.id)
    assert length(all_enqueued(worker: IssueTicketsWorker)) == 1
  end
end
