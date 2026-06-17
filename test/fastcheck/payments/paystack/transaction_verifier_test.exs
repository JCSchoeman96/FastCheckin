defmodule FastCheck.Payments.Paystack.TransactionVerifierTest do
  use ExUnit.Case, async: false

  alias FastCheck.Payments.Paystack.TransactionVerifier

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
    Application.put_env(:fastcheck, :paystack_public_key, "pk_test_fake")
    Application.put_env(:fastcheck, :paystack_secret_key, "sk_test_fake")
    Application.put_env(:fastcheck, :paystack_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :paystack_allowed_channels, ["card"])

    :ok
  end

  test "verifies transaction by reference and normalizes response data" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn req ->
      assert req.url.path == "/transaction/verify/FC-VERIFY-1"

      {:ok,
       %Req.Response{
         status: 200,
         body:
           ~s({"status": true, "data": {"reference":"FC-VERIFY-1","status":"success","amount":12500,"currency":"ZAR","paid_at":"2026-06-17T08:00:00Z","gateway_response":"Approved"}})
       }}
    end)

    assert {:ok, result} = TransactionVerifier.verify("FC-VERIFY-1")
    assert result.provider_reference == "FC-VERIFY-1"
    assert result.provider_status == "success"
    assert result.amount == 12_500
    assert result.currency == "ZAR"
  end
end
