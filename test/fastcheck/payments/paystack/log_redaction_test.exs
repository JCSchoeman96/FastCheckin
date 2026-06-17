defmodule FastCheck.Payments.Paystack.LogRedactionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Observability.Redactor
  alias FastCheck.Payments.Paystack.TransactionInitializer

  setup do
    keys = [
      :paystack_enabled,
      :paystack_base_url,
      :paystack_public_key,
      :paystack_secret_key,
      :paystack_timeout_ms,
      :paystack_allowed_channels,
      :paystack_request_fun
    ]

    snapshot = for key <- keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    on_exit(fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end)

    Application.put_env(:fastcheck, :paystack_enabled, true)
    Application.put_env(:fastcheck, :paystack_base_url, "https://api.paystack.co")
    Application.put_env(:fastcheck, :paystack_public_key, "pk_test_fake_key")
    Application.put_env(:fastcheck, :paystack_secret_key, "sk_test_fake_key")
    Application.put_env(:fastcheck, :paystack_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :paystack_allowed_channels, ["card"])

    :ok
  end

  test "client logging does not expose authorization header, access_code, or buyer pii" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      {:ok,
       %Req.Response{
         status: 429,
         body:
           ~s({"status": false, "message": "rate limit", "data": {"authorization_url":"https://checkout.paystack.com/abc","access_code":"AC_123","email":"buyer@example.com","phone":"+27821234567"}})
       }}
    end)

    log =
      capture_log(fn ->
        assert {:error, _error} =
                 TransactionInitializer.initialize(%{
                   amount_cents: 20_000,
                   currency: "ZAR",
                   email: "buyer@example.com",
                   reference: "FC-LOG-1",
                   metadata: %{order_public_reference: "ORD-1"}
                 })
      end)

    refute log =~ "Bearer sk_test_fake_key"
    refute log =~ "sk_test_fake_key"
    refute log =~ "AC_123"
    refute log =~ "buyer@example.com"
    refute log =~ "27821234567"
  end

  test "redactor filters sensitive paystack fields" do
    redacted =
      Redactor.redact_map(%{
        authorization_url: "https://checkout.paystack.com/abc",
        access_code: "AC_123",
        paystack_secret_key: "sk_test_fake_key",
        buyer_email: "buyer@example.com"
      })

    assert redacted.authorization_url == "[FILTERED]"
    assert redacted.access_code == "[FILTERED]"
    assert redacted.paystack_secret_key == "[FILTERED]"
    assert redacted.buyer_email == "j***@example.com"
  end
end
