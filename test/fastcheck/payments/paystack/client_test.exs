defmodule FastCheck.Payments.Paystack.ClientTest do
  use ExUnit.Case, async: false

  alias FastCheck.Payments.Paystack.Client
  alias Req.Request
  alias Req.Response

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

  test "adds authorization header and timeout for initialize request" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn req ->
      assert req.method == :post
      assert req.options.receive_timeout == 10_000
      assert ["Bearer sk_test_fake"] == Request.get_header(req, "authorization")
      assert req.url.path == "/transaction/initialize"
      {:ok, %Response{status: 200, body: ~s({"status": true, "data": {"reference":"FC-1"}})}}
    end)

    assert {:ok, %{"status" => true}} = Client.post("/transaction/initialize", %{amount: 10_000})
  end

  test "normalizes provider 401 errors" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      {:ok, %Response{status: 401, body: ~s({"status": false, "message": "Unauthorized"})}}
    end)

    assert {:error, error} = Client.get("/transaction/verify/FC-1")
    assert error.type == :unauthorized
  end

  test "normalizes timeout errors" do
    Application.put_env(:fastcheck, :paystack_request_fun, fn _req ->
      {:error, %Req.TransportError{reason: :timeout}}
    end)

    assert {:error, error} = Client.get("/transaction/verify/FC-1")
    assert error.type == :timeout
    assert error.retryable?
  end
end
