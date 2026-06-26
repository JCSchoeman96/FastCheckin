defmodule FastCheck.Messaging.WhatsApp.ClientTest do
  use ExUnit.Case, async: false

  alias FastCheck.Messaging.WhatsApp.Client
  alias FastCheck.Messaging.WhatsApp.Response
  alias Req.Request

  @keys [
    :whatsapp_enabled,
    :whatsapp_graph_api_base_url,
    :whatsapp_graph_api_version,
    :whatsapp_phone_number_id,
    :whatsapp_access_token,
    :whatsapp_app_secret,
    :whatsapp_request_timeout_ms,
    :whatsapp_receive_timeout_ms,
    :whatsapp_sandbox_mode,
    :whatsapp_request_fun
  ]

  setup do
    snapshot = for key <- @keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    on_exit(fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end)

    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.test")
    Application.put_env(:fastcheck, :whatsapp_graph_api_version, "v99.0")
    Application.put_env(:fastcheck, :whatsapp_phone_number_id, "phone-number-123")
    Application.put_env(:fastcheck, :whatsapp_access_token, "EAAG_TEST_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_app_secret, "APP_SECRET")
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 11_000)
    Application.put_env(:fastcheck, :whatsapp_sandbox_mode, true)

    :ok
  end

  test "send_text posts to Meta messages endpoint with safe normalized payload" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn req ->
      assert req.method == :post
      assert req.url.path == "/v99.0/phone-number-123/messages"
      assert req.options.connect_options == [timeout: 5_000]
      assert req.options.receive_timeout == 11_000
      assert ["Bearer EAAG_TEST_TOKEN"] == Request.get_header(req, "authorization")
      assert ["application/json"] == Request.get_header(req, "accept")
      assert req.options.json["to"] == "27821234567"
      assert req.options.json["text"]["body"] == "Hallo"

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "messaging_product" => "whatsapp",
           "messages" => [%{"id" => "wamid.TEST"}],
           "contacts" => [%{"wa_id" => "27821234567"}]
         }
       }}
    end)

    assert {:ok, %Response{} = response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :accepted
    assert response.provider == :meta
    assert response.provider_message_id == "wamid.TEST"
    assert response.raw_status == 200
    refute response.retryable?
  end

  test "send_template posts template payload" do
    components = [%{"type" => "body", "parameters" => [%{"type" => "text", "text" => "ORD-1"}]}]

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn req ->
      assert req.options.json["to"] == "27821234567"
      assert req.options.json["type"] == "template"
      assert req.options.json["template"]["name"] == "fastcheck_payment_link_en"
      assert req.options.json["template"]["language"]["code"] == "en_US"
      assert req.options.json["template"]["components"] == components

      {:ok, %Req.Response{status: 201, body: %{"messages" => [%{"id" => "wamid.TEMPLATE"}]}}}
    end)

    assert {:ok, response} =
             Client.send_template("+27821234567", :payment_link_en, "en_US", components)

    assert response.status == :accepted
    assert response.provider_message_id == "wamid.TEMPLATE"
  end

  test "normalizes 2xx binary JSON response body" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:ok,
       %Req.Response{
         status: 200,
         body: ~s({"messaging_product":"whatsapp","messages":[{"id":"wamid.BINARY"}]})
       }}
    end)

    assert {:ok, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :accepted
    assert response.provider_message_id == "wamid.BINARY"
    assert response.raw_status == 200
  end

  test "invalid input returns validation error before HTTP call" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      flunk("request function must not be called for invalid input")
    end)

    assert {:error, response} = Client.send_text("27821234567", "Hallo")
    assert response.status == :validation_error
    assert response.retryable? == false
  end

  test "normalizes provider response classes and retryability" do
    cases = [
      {400, :validation_error, false, false},
      {401, :auth_error, false, false},
      {403, :auth_error, false, false},
      {429, :rate_limited, true, true},
      {500, :server_error, true, false},
      {503, :server_error, true, false},
      {418, :unknown_error, false, false}
    ]

    for {status, expected_status, retryable?, rate_limited?} <- cases do
      Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
        {:ok,
         %Req.Response{
           status: status,
           body: %{
             "error" => %{
               "code" => 131_000,
               "message" => "provider failed for +27821234567 with EAAG_TEST_TOKEN"
             }
           }
         }}
      end)

      assert {:error, response} = Client.send_text("+27821234567", "Hallo")
      assert response.status == expected_status
      assert response.raw_status == status
      assert response.retryable? == retryable?
      assert response.rate_limited? == rate_limited?
      assert response.provider_error_code == "131000"
      refute response.provider_error_message =~ "27821234567"
      refute response.provider_error_message =~ "EAAG_TEST_TOKEN"
    end
  end

  test "normalizes binary JSON provider error response classes" do
    cases = [
      {400, :validation_error, false, false},
      {401, :auth_error, false, false},
      {403, :auth_error, false, false},
      {429, :rate_limited, true, true},
      {500, :server_error, true, false}
    ]

    for {status, expected_status, retryable?, rate_limited?} <- cases do
      Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
        {:ok,
         %Req.Response{
           status: status,
           body: ~s({"error":{"code":131000,"message":"safe provider diagnostic"}})
         }}
      end)

      assert {:error, response} = Client.send_text("+27821234567", "Hallo")
      assert response.status == expected_status
      assert response.raw_status == status
      assert response.retryable? == retryable?
      assert response.rate_limited? == rate_limited?
      assert response.provider_error_code == "131000"
      assert response.provider_error_message == "safe provider diagnostic"
    end
  end

  test "normalizes timeout, transport errors, and raised request failures" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :timeout
    assert response.retryable?

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:error, %Req.TransportError{reason: :econnrefused}}
    end)

    assert {:error, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :transport_error
    assert response.retryable?

    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      raise "socket blew up with EAAG_TEST_TOKEN"
    end)

    assert {:error, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :transport_error
    assert response.retryable?
    refute inspect(response) =~ "EAAG_TEST_TOKEN"
  end

  test "malformed success response is safe unknown error" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:ok, %Req.Response{status: 200, body: %{"unexpected" => "shape"}}}
    end)

    assert {:error, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :unknown_error
    assert response.retryable? == false
    assert response.raw_status == 200
  end

  test "malformed binary JSON response returns safe unknown error without leaking raw body" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:ok,
       %Req.Response{
         status: 200,
         body: ~s({"messages":[{"id":"wamid.BAD"}], "raw_token": "EAAG_TEST_TOKEN")
       }}
    end)

    assert {:error, response} = Client.send_text("+27821234567", "Hallo")
    assert response.status == :unknown_error
    assert response.raw_status == 200
    refute inspect(response) =~ "EAAG_TEST_TOKEN"
    refute inspect(response) =~ "wamid.BAD"
  end
end
