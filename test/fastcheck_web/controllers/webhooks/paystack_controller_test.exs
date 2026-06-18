defmodule FastCheckWeb.Webhooks.PaystackControllerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import ExUnit.CaptureLog

  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport

  @webhook_path "/api/sales/paystack/webhook"

  setup do
    PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    on_exit(fn -> PaystackSupport.flush_webhook_dedupe_keys!() end)
    :ok
  end

  test "valid signed webhook creates one payment event and one oban job", %{conn: conn} do
    body = PaystackSupport.charge_success_webhook_body()
    signature = PaystackSupport.sign_webhook_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200)
    assert count_payment_events() == 1
    assert [%{args: %{"payment_event_id" => _}}] = all_enqueued(worker: PaystackWebhookWorker)
  end

  test "invalid signature returns 401 without row or job", %{conn: conn} do
    body = PaystackSupport.charge_success_webhook_body()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", "invalid")
      |> post(@webhook_path, body)

    assert response(conn, 401)
    assert count_payment_events() == 0
    refute_enqueued(worker: PaystackWebhookWorker)
  end

  test "malformed JSON returns 400 without row or job", %{conn: conn} do
    body = "{not-json"
    signature = PaystackSupport.sign_webhook_body(body)

    log =
      capture_log(fn ->
        conn =
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-paystack-signature", signature)
          |> post(@webhook_path, body)

        assert response(conn, 400)
      end)

    refute log =~ signature
    refute log =~ body
    assert count_payment_events() == 0
    refute_enqueued(worker: PaystackWebhookWorker)
  end

  test "duplicate provider_event_id returns 200 with one row and one job", %{conn: conn} do
    event_id = "evt-dup-#{System.unique_integer([:positive])}"
    body = PaystackSupport.charge_success_webhook_body(provider_event_id: event_id)
    signature = PaystackSupport.sign_webhook_body(body)

    conn1 =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", signature)
      |> post(@webhook_path, body)

    assert response(conn1, 200)

    conn2 =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", signature)
      |> post(@webhook_path, body)

    assert response(conn2, 200)
    assert count_payment_events() == 1
    assert length(all_enqueued(worker: PaystackWebhookWorker)) == 1
  end

  test "raw body HMAC uses exact bytes including whitespace", %{conn: conn} do
    event_id = "evt-raw-#{System.unique_integer([:positive])}"

    body =
      ~S({"id":") <> event_id <> ~S(","event":"charge.success","data":{"reference":"ref-raw-1"}})

    signature = PaystackSupport.sign_webhook_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200)
    assert count_payment_events() == 1
  end

  test "non-webhook POST does not retain raw body in conn.private", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/mobile/login", Jason.encode!(%{event_id: 1, credential: "x"}))

    refute Map.has_key?(conn.private, :raw_body)
  end

  test "webhook works with only paystack enabled and secret key configured", %{conn: conn} do
    Application.put_env(:fastcheck, :paystack_public_key, nil)
    Application.put_env(:fastcheck, :paystack_base_url, nil)

    body = PaystackSupport.charge_success_webhook_body()
    signature = PaystackSupport.sign_webhook_body(body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-paystack-signature", signature)
      |> post(@webhook_path, body)

    assert response(conn, 200)
    assert count_payment_events() == 1
  end

  defp count_payment_events do
    %{rows: [[count]]} = FastCheck.Repo.query!("SELECT count(*)::int FROM sales_payment_events")
    count
  end
end
