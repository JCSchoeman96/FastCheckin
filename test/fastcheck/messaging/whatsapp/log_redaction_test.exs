defmodule FastCheck.Messaging.WhatsApp.LogRedactionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Messaging.WhatsApp.Client

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
    Application.put_env(:fastcheck, :whatsapp_access_token, "EAAG_SECRET_ACCESS_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_app_secret, "META_APP_SECRET")
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 11_000)
    Application.put_env(:fastcheck, :whatsapp_sandbox_mode, true)

    :ok
  end

  test "provider failure logs and response structs do not expose secrets or PII" do
    Application.put_env(:fastcheck, :whatsapp_request_fun, fn _req ->
      {:ok,
       %Req.Response{
         status: 429,
         body: %{
           "error" => %{
             "code" => 130_429,
             "message" =>
               "Rate limited +27821234567 EAAG_SECRET_ACCESS_TOKEN https://scan.voelgoed.co.za/tickets/secret-token QR_TOKEN DELIVERY_TOKEN"
           }
         }
       }}
    end)

    log =
      capture_log(fn ->
        assert {:error, response} =
                 Client.send_text(
                   "+27821234567",
                   "Ticket ready: https://scan.voelgoed.co.za/tickets/secret-token"
                 )

        inspected = inspect(response)

        refute inspected =~ "EAAG_SECRET_ACCESS_TOKEN"
        refute inspected =~ "Authorization"
        refute inspected =~ "27821234567"
        refute inspected =~ "Ticket ready"
        refute inspected =~ "secret-token"
        refute inspected =~ "QR_TOKEN"
        refute inspected =~ "DELIVERY_TOKEN"
      end)

    refute log =~ "EAAG_SECRET_ACCESS_TOKEN"
    refute log =~ "Bearer"
    refute log =~ "Authorization"
    refute log =~ "27821234567"
    refute log =~ "Ticket ready"
    refute log =~ "secret-token"
    refute log =~ "QR_TOKEN"
    refute log =~ "DELIVERY_TOKEN"
  end
end
