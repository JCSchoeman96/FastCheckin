defmodule FastCheck.Payments.Paystack.ConfigTest do
  use ExUnit.Case, async: false

  alias FastCheck.Payments.Paystack.Config

  setup do
    keys = [
      :paystack_enabled,
      :paystack_environment,
      :paystack_base_url,
      :paystack_public_key,
      :paystack_secret_key,
      :paystack_timeout_ms,
      :paystack_allowed_channels,
      :paystack_callback_url,
      :paystack_webhook_url
    ]

    snapshot = for key <- keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    on_exit(fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end)

    :ok
  end

  test "validate_for_boot passes when paystack is disabled and secrets are absent" do
    Application.put_env(:fastcheck, :paystack_enabled, false)
    Application.delete_env(:fastcheck, :paystack_public_key)
    Application.delete_env(:fastcheck, :paystack_secret_key)

    assert :ok = Config.validate_for_boot()
  end

  test "validate_for_call returns missing_config when enabled but required values are missing" do
    Application.put_env(:fastcheck, :paystack_enabled, true)
    Application.delete_env(:fastcheck, :paystack_secret_key)

    assert {:error, error} = Config.validate_for_call()
    assert error.type == :missing_config
  end

  test "validate_for_call rejects invalid configured channels" do
    Application.put_env(:fastcheck, :paystack_enabled, true)
    Application.put_env(:fastcheck, :paystack_public_key, "pk_test_fake")
    Application.put_env(:fastcheck, :paystack_secret_key, "sk_test_fake")
    Application.put_env(:fastcheck, :paystack_base_url, "https://api.paystack.co")
    Application.put_env(:fastcheck, :paystack_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :paystack_allowed_channels, ["card", "not_real"])

    assert {:error, error} = Config.validate_for_call()
    assert error.type == :invalid_request
    assert error.safe_metadata.invalid_channels == ["not_real"]
  end

  test "parse_allowed_channels accepts csv and allows empty" do
    assert Config.parse_allowed_channels("card, bank_transfer, eft") == [
             "card",
             "bank_transfer",
             "eft"
           ]

    assert Config.parse_allowed_channels("  ") == []
  end

  test "reference validation enforces paystack-safe charset" do
    assert {:ok, "FC-ORD.123=ABC"} = Config.normalize_reference(" FC-ORD.123=ABC ")
    assert Config.valid_reference?("FC-ORD-1")
    refute Config.valid_reference?("FC ORD 1")
  end

  test "inspect redacts paystack keys" do
    Application.put_env(:fastcheck, :paystack_enabled, true)
    Application.put_env(:fastcheck, :paystack_public_key, "pk_test_fake")
    Application.put_env(:fastcheck, :paystack_secret_key, "sk_test_fake")
    Application.put_env(:fastcheck, :paystack_base_url, "https://api.paystack.co")
    Application.put_env(:fastcheck, :paystack_timeout_ms, 10_000)

    inspected = inspect(Config.get())

    refute inspected =~ "sk_"
    assert inspected =~ "[FILTERED]"
  end
end
