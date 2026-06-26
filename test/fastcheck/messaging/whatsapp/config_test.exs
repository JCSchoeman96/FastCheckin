defmodule FastCheck.Messaging.WhatsApp.ConfigTest do
  use ExUnit.Case, async: false

  alias FastCheck.Messaging.WhatsApp.Config

  @keys [
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

  setup do
    snapshot = for key <- @keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    on_exit(fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end)

    :ok
  end

  test "validate_for_boot passes when whatsapp outbound is disabled and secrets are absent" do
    Application.put_env(:fastcheck, :whatsapp_enabled, false)
    Application.delete_env(:fastcheck, :whatsapp_access_token)
    Application.delete_env(:fastcheck, :whatsapp_phone_number_id)
    Application.delete_env(:fastcheck, :whatsapp_graph_api_version)

    assert :ok = Config.validate_for_boot()
  end

  test "validate_for_call requires explicit enabled provider config" do
    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.com")
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 10_000)
    Application.delete_env(:fastcheck, :whatsapp_graph_api_version)
    Application.delete_env(:fastcheck, :whatsapp_phone_number_id)
    Application.delete_env(:fastcheck, :whatsapp_access_token)

    assert {:error, error} = Config.validate_for_call()
    assert error.status == :missing_config
    assert error.provider == :meta
    assert error.retryable? == false
  end

  test "validate_for_call rejects non-positive timeouts when enabled" do
    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.com")
    Application.put_env(:fastcheck, :whatsapp_graph_api_version, "v99.0")
    Application.put_env(:fastcheck, :whatsapp_phone_number_id, "123456")
    Application.put_env(:fastcheck, :whatsapp_access_token, "meta_test_token")
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 0)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 10_000)

    assert {:error, error} = Config.validate_for_call()
    assert error.status == :missing_config
    assert error.provider_error_code == "whatsapp_request_timeout_ms"
  end

  test "validate_for_webhook requires app secret verify token TTLs and queue" do
    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_app_secret, "META_APP_SECRET")
    Application.put_env(:fastcheck, :whatsapp_verify_token, "VERIFY_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_session_ttl_seconds, 86_400)
    Application.put_env(:fastcheck, :whatsapp_dedupe_ttl_seconds, 86_400)
    Application.put_env(:fastcheck, :whatsapp_inbound_queue_enabled, true)

    assert {:ok, config} = Config.validate_for_webhook()
    assert config.app_secret == "META_APP_SECRET"
    assert config.verify_token == "VERIFY_TOKEN"

    Application.put_env(:fastcheck, :whatsapp_inbound_queue_enabled, false)

    assert {:error, error} = Config.validate_for_webhook()
    assert error.status == :missing_config
    assert error.provider_error_code == "whatsapp_inbound_queue_enabled"
  end

  test "get, inspect, and redacted_summary never expose access token or app secret" do
    Application.put_env(:fastcheck, :whatsapp_enabled, true)
    Application.put_env(:fastcheck, :whatsapp_graph_api_base_url, "https://graph.facebook.com")
    Application.put_env(:fastcheck, :whatsapp_graph_api_version, "v99.0")
    Application.put_env(:fastcheck, :whatsapp_phone_number_id, "123456")
    Application.put_env(:fastcheck, :whatsapp_access_token, "EAAG_SECRET_ACCESS_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_app_secret, "META_APP_SECRET")
    Application.put_env(:fastcheck, :whatsapp_verify_token, "VERIFY_TOKEN")
    Application.put_env(:fastcheck, :whatsapp_request_timeout_ms, 5_000)
    Application.put_env(:fastcheck, :whatsapp_receive_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :whatsapp_sandbox_mode, true)

    inspected = inspect(Config.get())
    summary = inspect(Config.redacted_summary())

    refute inspected =~ "EAAG_SECRET_ACCESS_TOKEN"
    refute inspected =~ "META_APP_SECRET"
    refute inspected =~ "VERIFY_TOKEN"
    refute summary =~ "EAAG_SECRET_ACCESS_TOKEN"
    refute summary =~ "META_APP_SECRET"
    refute summary =~ "VERIFY_TOKEN"
    assert inspected =~ "[FILTERED]"
    assert summary =~ "[FILTERED]"
  end
end
