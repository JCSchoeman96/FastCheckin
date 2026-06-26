defmodule FastCheck.Messaging.WhatsApp.WebhookTestSupport do
  @moduledoc false

  @config_keys [
    :whatsapp_enabled,
    :whatsapp_graph_api_base_url,
    :whatsapp_graph_api_version,
    :whatsapp_phone_number_id,
    :whatsapp_business_account_id,
    :whatsapp_access_token,
    :whatsapp_app_secret,
    :whatsapp_verify_token,
    :whatsapp_request_timeout_ms,
    :whatsapp_receive_timeout_ms,
    :whatsapp_sandbox_mode,
    :whatsapp_session_ttl_seconds,
    :whatsapp_dedupe_ttl_seconds,
    :whatsapp_inbound_queue_enabled,
    :whatsapp_request_fun
  ]

  def setup_whatsapp! do
    snapshot = for key <- @config_keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.test")
    Application.put_env(:fastcheck, :whatsapp_graph_api_version, "v99.0")
    Application.put_env(:fastcheck, :whatsapp_phone_number_id, "phone-number-123")
    Application.put_env(:fastcheck, :whatsapp_business_account_id, "business-123")
    Application.put_env(:fastcheck, :whatsapp_access_token, "EAAG_SECRET_ACCESS_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_app_secret, app_secret())
    Application.put_env(:fastcheck, :whatsapp_verify_token, verify_token())
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :whatsapp_sandbox_mode, true)
    Application.put_env(:fastcheck, :whatsapp_session_ttl_seconds, 86_400)
    Application.put_env(:fastcheck, :whatsapp_dedupe_ttl_seconds, 86_400)
    Application.put_env(:fastcheck, :whatsapp_inbound_queue_enabled, true)

    fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end
  end

  def verify_token, do: "verify-token-safe"
  def app_secret, do: "meta-app-secret-safe"

  def text_body(opts \\ []) do
    provider_message_id =
      Keyword.get(opts, :provider_message_id, "wamid.#{System.unique_integer([:positive])}")

    phone = Keyword.get(opts, :phone_e164, "+27821234567")
    wa_id = Keyword.get(opts, :wa_id, String.trim_leading(phone, "+"))
    text = Keyword.get(opts, :text, "2")

    Jason.encode!(%{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "business-123",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "metadata" => %{
                  "display_phone_number" => "27111222333",
                  "phone_number_id" => "phone-number-123"
                },
                "contacts" => [
                  %{
                    "wa_id" => wa_id,
                    "profile" => %{"name" => "Sensitive Customer"}
                  }
                ],
                "messages" => [
                  %{
                    "from" => wa_id,
                    "id" => provider_message_id,
                    "timestamp" => "1782477600",
                    "type" => "text",
                    "text" => %{"body" => text}
                  }
                ]
              }
            }
          ]
        }
      ]
    })
  end

  def unsupported_body(opts \\ []) do
    text_body(opts)
    |> Jason.decode!()
    |> put_in(
      [
        "entry",
        Access.at(0),
        "changes",
        Access.at(0),
        "value",
        "messages",
        Access.at(0)
      ],
      %{
        "from" => Keyword.get(opts, :wa_id, "27821234567"),
        "id" => Keyword.get(opts, :provider_message_id, "wamid.unsupported"),
        "timestamp" => "1782477600",
        "type" => "image",
        "image" => %{"id" => "media-secret"}
      }
    )
    |> Jason.encode!()
  end

  def status_body do
    Jason.encode!(%{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "business-123",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "statuses" => [
                  %{"id" => "wamid.status", "status" => "delivered", "timestamp" => "1782477600"}
                ]
              }
            }
          ]
        }
      ]
    })
  end

  def sign_body(body, secret \\ app_secret()) when is_binary(body) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  def flush_redis_keys! do
    for pattern <- [
          "fastcheck:whatsapp:dedupe:message:*",
          "fastcheck:whatsapp:session:*"
        ] do
      case Redix.command(FastCheck.Redix, ["KEYS", pattern]) do
        {:ok, []} -> :ok
        {:ok, keys} -> Redix.command(FastCheck.Redix, ["DEL" | keys])
        {:error, _reason} -> :ok
      end
    end
  end
end
