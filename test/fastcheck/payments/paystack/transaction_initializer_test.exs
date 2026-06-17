defmodule FastCheck.Payments.Paystack.TransactionInitializerTest do
  use ExUnit.Case, async: false

  alias FastCheck.Payments.Paystack.TransactionInitializer

  setup do
    keys = [
      :paystack_enabled,
      :paystack_base_url,
      :paystack_public_key,
      :paystack_secret_key,
      :paystack_timeout_ms,
      :paystack_allowed_channels,
      :paystack_request_fun,
      :paystack_callback_url
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
    Application.put_env(:fastcheck, :paystack_allowed_channels, ["card", "bank_transfer"])

    Application.put_env(
      :fastcheck,
      :paystack_callback_url,
      "https://scan.voelgoed.co.za/sales/payments/paystack/callback"
    )

    :ok
  end

  test "initializes a transaction and normalizes sensitive response values" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn req ->
      assert req.url.path == "/transaction/initialize"
      assert req.options.json[:channels] == ["card", "bank_transfer"]

      {:ok,
       %Req.Response{
         status: 200,
         body:
           ~s({"status": true, "message": "ok", "data": {"reference":"FC-REF-1","authorization_url":"https://checkout.paystack.com/abc","access_code":"AC_123"}})
       }}
    end)

    assert {:ok, result} =
             TransactionInitializer.initialize(%{
               amount_cents: 12_500,
               currency: "ZAR",
               email: "buyer@example.com",
               reference: "FC-REF-1",
               metadata: %{order_public_reference: "ORD-1", event_id: 1}
             })

    assert result.provider_reference == "FC-REF-1"
    assert result.authorization_url =~ "paystack"
    assert result.access_code == "AC_123"
    assert result.safe_data["authorization_url"] == "[FILTERED]"

    inspected = inspect(result)
    refute inspected =~ "authorization_url"
    refute inspected =~ "checkout.paystack"
    refute inspected =~ "access_code"
  end

  test "omits channels when config channel list is empty" do
    Application.put_env(:fastcheck, :paystack_allowed_channels, [])

    Application.put_env(:fastcheck, :paystack_request_fun, fn req ->
      refute Map.has_key?(req.options.json, :channels)

      {:ok,
       %Req.Response{status: 200, body: ~s({"status": true, "data": {"reference":"FC-REF-2"}})}}
    end)

    assert {:ok, _result} =
             TransactionInitializer.initialize(%{
               amount_cents: 10_000,
               currency: "ZAR",
               email: "buyer@example.com",
               reference: "FC-REF-2",
               metadata: %{}
             })
  end
end
