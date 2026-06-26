defmodule FastCheckWeb.Webhooks.WhatsAppControllerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog

  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
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

  defp count_conversations do
    %{rows: [[count]]} = FastCheck.Repo.query!("SELECT count(*)::int FROM sales_conversations")
    count
  end
end
