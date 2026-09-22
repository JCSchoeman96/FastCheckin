defmodule FastCheckWeb.Webhooks.WhatsAppControllerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog

  alias FastCheck.Messaging.WhatsApp.SessionStore
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Workers.WhatsAppInboundWorker

  @webhook_path "/api/v1/webhooks/whatsapp"

  setup do
    cleanup = WebhookTestSupport.setup_whatsapp!()
    WebhookTestSupport.flush_redis_keys!()

    on_exit(fn ->
      WebhookTestSupport.flush_redis_keys!()
      cleanup.()
    end)

    :ok
  end

  test "GET verification returns challenge only for valid verify token", %{conn: conn} do
    conn =
      get(conn, @webhook_path, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => WebhookTestSupport.verify_token(),
        "hub.challenge" => "challenge-123"
      })

    assert response(conn, 200) == "challenge-123"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "GET verification rejects unsafe challenge values", %{conn: conn} do
    conn =
      get(conn, @webhook_path, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => WebhookTestSupport.verify_token(),
        "hub.challenge" => String.duplicate("a", 257)
      })

    assert response(conn, 400) == ""
  end

  test "GET verification rejects wrong token", %{conn: conn} do
    conn =
      get(conn, @webhook_path, %{
        "hub.mode" => "subscribe",
        "hub.verify_token" => "bad",
        "hub.challenge" => "challenge-123"
      })

    assert response(conn, 403) == ""
  end

  test "POST rejects missing and invalid signatures before side effects", %{conn: conn} do
    body = WebhookTestSupport.text_body(provider_message_id: "wamid.invalid-sig")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@webhook_path, body)

    assert response(conn, 401) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=bad")
      |> post(@webhook_path, body)

    assert response(conn, 401) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "POST verifies signature against exact raw bytes and enqueues one worker", %{conn: conn} do
    body =
      WebhookTestSupport.text_body(
        provider_message_id: "wamid.controller-1",
        text: "private customer menu reply"
      )

    signature = WebhookTestSupport.sign_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 1

    assert_enqueued(
      worker: WhatsAppInboundWorker,
      args: %{
        "provider_message_id" => "wamid.controller-1",
        "message_type" => "text"
      }
    )

    [job] = all_enqueued(worker: WhatsAppInboundWorker)
    refute inspect(job.args) =~ "private customer menu reply"
    refute inspect(job.args) =~ "+27821234567"
    refute inspect(job.args) =~ "27821234567"
    refute Map.has_key?(job.args, "text_body")
    refute Map.has_key?(job.args, "phone_e164")
    refute Map.has_key?(job.args, "wa_id")
  end

  test "signed wrong-WABA messages are acknowledged without domain or Redis side effects", %{
    conn: conn
  } do
    provider_message_id = "wamid.wrong-waba"
    wa_id = "27821234567"

    body =
      WebhookTestSupport.text_body(
        provider_message_id: provider_message_id,
        business_account_id: "business-other",
        wa_id: wa_id
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", dedupe_key(provider_message_id)])

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", SessionStore.key_for_wa_id(wa_id)])
  end

  test "signed wrong-phone messages are acknowledged without domain or Redis side effects", %{
    conn: conn
  } do
    provider_message_id = "wamid.wrong-phone"
    wa_id = "27821234568"

    body =
      WebhookTestSupport.text_body(
        provider_message_id: provider_message_id,
        phone_number_id: "phone-other",
        wa_id: wa_id
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", dedupe_key(provider_message_id)])

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", SessionStore.key_for_wa_id(wa_id)])
  end

  test "mixed payloads process only the matching change", %{conn: conn} do
    matching_id = "wamid.mixed-match"
    other_id = "wamid.mixed-other"

    matching =
      WebhookTestSupport.text_body(
        provider_message_id: matching_id,
        phone_e164: "+27821234569"
      )
      |> Jason.decode!()

    other =
      WebhookTestSupport.text_body(
        provider_message_id: other_id,
        phone_number_id: "phone-other",
        phone_e164: "+27821234570"
      )
      |> Jason.decode!()

    mixed =
      matching
      |> put_in(
        ["entry", Access.at(0), "changes"],
        get_in(matching, ["entry", Access.at(0), "changes"]) ++
          get_in(other, ["entry", Access.at(0), "changes"])
      )
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(mixed))
      |> post(@webhook_path, mixed)

    assert response(conn, 200) == ""
    assert count_conversations() == 1
    assert_enqueued(worker: WhatsAppInboundWorker, args: %{"provider_message_id" => matching_id})

    refute Enum.any?(all_enqueued(worker: WhatsAppInboundWorker), fn job ->
             job.args["provider_message_id"] == other_id
           end)
  end

  test "duplicate provider message does not enqueue twice", %{conn: conn} do
    body = WebhookTestSupport.text_body(provider_message_id: "wamid.duplicate")
    signature = WebhookTestSupport.sign_body(body)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(@webhook_path, body)
    |> response(200)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(@webhook_path, body)
    |> response(200)

    assert count_conversations() == 1
    assert length(all_enqueued(worker: WhatsAppInboundWorker)) == 1
  end

  test "malformed JSON does not log body signature or create side effects", %{conn: conn} do
    body = "{not-json"
    signature = WebhookTestSupport.sign_body(body)

    log =
      capture_log(fn ->
        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-hub-signature-256", signature)
          |> post(@webhook_path, body)

        assert response(conn, 400) == ""
      end)

    refute log =~ body
    refute log =~ signature
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "status-only payload is accepted as no-op", %{conn: conn} do
    body = WebhookTestSupport.status_body()
    signature = WebhookTestSupport.sign_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "signed scoped status callback reconciles without inbound side effects", %{conn: conn} do
    attempt_id = insert_provider_accepted_attempt!("wamid.controller-status")

    body =
      WebhookTestSupport.status_body(
        provider_message_id: "wamid.controller-status",
        status: "delivered"
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert snapshot_attempt!(attempt_id).status == "delivered"
    assert evidence_count(attempt_id) == 1
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "mixed scoped status and message changes use both pipelines", %{conn: conn} do
    status_wamid = "wamid.controller-mixed-status"
    message_wamid = "wamid.controller-mixed-message"
    attempt_id = insert_provider_accepted_attempt!(status_wamid)

    status_payload =
      WebhookTestSupport.status_body(provider_message_id: status_wamid)
      |> Jason.decode!()

    message_payload =
      WebhookTestSupport.text_body(provider_message_id: message_wamid)
      |> Jason.decode!()

    body =
      status_payload
      |> put_in(
        ["entry", Access.at(0), "changes"],
        get_in(status_payload, ["entry", Access.at(0), "changes"]) ++
          get_in(message_payload, ["entry", Access.at(0), "changes"])
      )
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert snapshot_attempt!(attempt_id).status == "delivered"
    assert evidence_count(attempt_id) == 1
    assert count_conversations() == 1

    assert_enqueued(
      worker: WhatsAppInboundWorker,
      args: %{"provider_message_id" => message_wamid}
    )
  end

  test "invalid signature leaves status evidence and projection unchanged", %{conn: conn} do
    attempt_id = insert_provider_accepted_attempt!("wamid.controller-invalid-signature")

    body =
      WebhookTestSupport.status_body(
        provider_message_id: "wamid.controller-invalid-signature",
        status: "read"
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=bad")
      |> post(@webhook_path, body)

    assert response(conn, 401) == ""
    assert snapshot_attempt!(attempt_id).status == "provider_accepted"
    assert evidence_count(attempt_id) == 0
  end

  test "wrong WABA status is acknowledged without evidence", %{conn: conn} do
    attempt_id = insert_provider_accepted_attempt!("wamid.controller-wrong-waba")

    body =
      WebhookTestSupport.status_body(
        provider_message_id: "wamid.controller-wrong-waba",
        business_account_id: "business-other"
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert snapshot_attempt!(attempt_id).status == "provider_accepted"
    assert evidence_count(attempt_id) == 0
  end

  test "wrong phone status is acknowledged without evidence", %{conn: conn} do
    attempt_id = insert_provider_accepted_attempt!("wamid.controller-wrong-phone")

    body =
      WebhookTestSupport.status_body(
        provider_message_id: "wamid.controller-wrong-phone",
        phone_number_id: "phone-other"
      )

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert snapshot_attempt!(attempt_id).status == "provider_accepted"
    assert evidence_count(attempt_id) == 0
  end

  test "signed wrong-scope status payload is acknowledged as a no-op", %{conn: conn} do
    body = WebhookTestSupport.status_body(business_account_id: "business-other")
    signature = WebhookTestSupport.sign_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "signed payload without WABA identity is acknowledged without side effects", %{conn: conn} do
    provider_message_id = "wamid.missing-waba"
    wa_id = "27821234572"

    body =
      WebhookTestSupport.text_body(provider_message_id: provider_message_id, wa_id: wa_id)
      |> Jason.decode!()
      |> update_in(["entry", Access.at(0)], &Map.delete(&1, "id"))
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", dedupe_key(provider_message_id)])

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", SessionStore.key_for_wa_id(wa_id)])
  end

  test "signed payload without phone identity is acknowledged without side effects", %{conn: conn} do
    provider_message_id = "wamid.missing-phone"
    wa_id = "27821234573"

    body =
      WebhookTestSupport.text_body(provider_message_id: provider_message_id, wa_id: wa_id)
      |> Jason.decode!()
      |> update_in(
        ["entry", Access.at(0), "changes", Access.at(0), "value", "metadata"],
        &Map.delete(&1, "phone_number_id")
      )
      |> Jason.encode!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0
    refute_enqueued(worker: WhatsAppInboundWorker)
    assert {:ok, 0} = Redix.command(FastCheck.Redix, ["EXISTS", dedupe_key(provider_message_id)])

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", SessionStore.key_for_wa_id(wa_id)])
  end

  test "out-of-scope payloads do not log provider or customer values", %{conn: conn} do
    body =
      WebhookTestSupport.text_body(
        provider_message_id: "wamid.log-scope",
        business_account_id: "business-other",
        phone_e164: "+27821234571",
        text: "private customer text"
      )

    log =
      capture_log(fn ->
        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-hub-signature-256", WebhookTestSupport.sign_body(body))
          |> post(@webhook_path, body)

        assert response(conn, 200) == ""
      end)

    refute log =~ "private customer text"
    refute log =~ "27821234571"
    refute log =~ WebhookTestSupport.app_secret()
  end

  test "unsupported media payload is accepted as no-op without state", %{conn: conn} do
    wa_id = "27821234567"

    body =
      WebhookTestSupport.unsupported_body(provider_message_id: "wamid.unsupported-controller")

    signature = WebhookTestSupport.sign_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200) == ""
    assert count_conversations() == 0

    assert {:ok, 0} =
             Redix.command(FastCheck.Redix, ["EXISTS", SessionStore.key_for_wa_id(wa_id)])

    refute_enqueued(worker: WhatsAppInboundWorker)
  end

  test "post-dedupe enqueue failure releases claim and allows signed retry", %{conn: conn} do
    provider_message_id = "wamid.compensation-controller"
    body = WebhookTestSupport.text_body(provider_message_id: provider_message_id)
    signature = WebhookTestSupport.sign_body(body)

    Application.put_env(:fastcheck, :whatsapp_inbound_force_enqueue_failure, true)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 503) == ""
    assert {:ok, nil} = Redix.command(FastCheck.Redix, ["GET", dedupe_key(provider_message_id)])
    refute_enqueued(worker: WhatsAppInboundWorker)

    Application.put_env(:fastcheck, :whatsapp_inbound_force_enqueue_failure, false)

    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(@webhook_path, body)
    |> response(200)

    assert count_conversations() == 1

    assert_enqueued(
      worker: WhatsAppInboundWorker,
      args: %{
        "provider_message_id" => provider_message_id,
        "message_type" => "text"
      }
    )
  end

  test "text encryption failure fails closed before enqueue and releases dedupe claim", %{
    conn: conn
  } do
    provider_message_id = "wamid.encrypt-failure-controller"
    body = WebhookTestSupport.text_body(provider_message_id: provider_message_id, text: "1")
    signature = WebhookTestSupport.sign_body(body)
    encryption_key = Application.get_env(:fastcheck, :encryption_key)

    on_exit(fn ->
      if is_nil(encryption_key),
        do: Application.delete_env(:fastcheck, :encryption_key),
        else: Application.put_env(:fastcheck, :encryption_key, encryption_key)
    end)

    Application.delete_env(:fastcheck, :encryption_key)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", signature)
      |> post(@webhook_path, body)

    assert response(conn, 503) == ""
    refute_enqueued(worker: WhatsAppInboundWorker)
    assert {:ok, nil} = Redix.command(FastCheck.Redix, ["GET", dedupe_key(provider_message_id)])
  end

  defp count_conversations do
    %{rows: [[count]]} = FastCheck.Repo.query!("SELECT count(*)::int FROM sales_conversations")
    count
  end

  defp dedupe_key(provider_message_id) do
    "fastcheck:whatsapp:dedupe:message:#{provider_message_id}"
  end

  defp insert_provider_accepted_attempt!(provider_message_id) do
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(90_001)

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           inserted_at, updated_at)
        VALUES ($1, 90001, 'whatsapp', 'paid_verified', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-CONTROLLER-#{System.unique_integer([:positive])}"]
      )

    %{rows: [[attempt_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_delivery_attempts
          (sales_order_id, ticket_issue_id, channel, provider, status, provider_message_id,
           provider_status, provider_status_at, attempt_number, inserted_at, updated_at)
        VALUES ($1, NULL, 'whatsapp', 'meta', 'provider_accepted', $2, 'accepted',
                '2026-06-26 12:40:00', 1, now(), now())
        RETURNING id
        """,
        [order_id, provider_message_id]
      )

    attempt_id
  end

  defp snapshot_attempt!(attempt_id) do
    %{rows: [[status]]} =
      Repo.query!(
        "SELECT status FROM sales_delivery_attempts WHERE id = $1",
        [attempt_id]
      )

    %{status: status}
  end

  defp evidence_count(attempt_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM sales_delivery_status_events WHERE delivery_attempt_id = $1",
        [attempt_id]
      )

    count
  end
end
