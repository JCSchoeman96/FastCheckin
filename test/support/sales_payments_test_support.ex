defmodule FastCheck.Sales.Payments.TestSupport do
  @moduledoc false

  alias Ash.Query

  def setup_paystack! do
    keys = [
      :paystack_enabled,
      :paystack_base_url,
      :paystack_public_key,
      :paystack_secret_key,
      :paystack_timeout_ms,
      :paystack_allowed_channels,
      :paystack_request_fun,
      :paystack_callback_url,
      :paystack_initializing_stale_after_seconds
    ]

    snapshot = for key <- keys, into: %{}, do: {key, Application.get_env(:fastcheck, key)}

    on_exit = fn ->
      Enum.each(snapshot, fn {key, value} ->
        if is_nil(value),
          do: Application.delete_env(:fastcheck, key),
          else: Application.put_env(:fastcheck, key, value)
      end)
    end

    Application.put_env(:fastcheck, :paystack_enabled, true)
    Application.put_env(:fastcheck, :paystack_base_url, "https://api.paystack.co")
    Application.put_env(:fastcheck, :paystack_public_key, "pk_test_fake")
    Application.put_env(:fastcheck, :paystack_secret_key, "sk_test_fake")
    Application.put_env(:fastcheck, :paystack_timeout_ms, 10_000)
    Application.put_env(:fastcheck, :paystack_allowed_channels, [])
    Application.put_env(:fastcheck, :paystack_initializing_stale_after_seconds, 120)

    Application.put_env(
      :fastcheck,
      :paystack_callback_url,
      "https://scan.voelgoed.co.za/sales/payments/paystack/callback"
    )

    on_exit
  end

  def checkout_ready_for_payment!(offer, overrides \\ %{}) do
    alias FastCheck.Sales.Checkout
    alias FastCheck.SalesCheckoutFixtures, as: Fixtures

    input =
      Fixtures.checkout_input(
        Map.merge(
          %{
            ticket_offer_id: offer.id,
            idempotency_key: "pay-init-#{System.unique_integer([:positive])}"
          },
          overrides
        )
      )

    case Checkout.start_checkout(input, Fixtures.system_actor(),
           effective_sales_channel: "whatsapp"
         ) do
      {:ok, %{order: order, checkout_session: session}} ->
        {order, session}

      other ->
        raise "checkout setup failed: #{inspect(other)}"
    end
  end

  def success_request_fun(opts \\ []) do
    url = Keyword.get(opts, :authorization_url, "https://checkout.paystack.com/safe-test")
    access_code = Keyword.get(opts, :access_code, "AC_SAFE")

    fn req ->
      reference = req.options.json[:reference]

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             status: true,
             message: "ok",
             data: %{
               reference: reference,
               authorization_url: url,
               access_code: access_code
             }
           })
       }}
    end
  end

  def counting_request_fun(inner_fun) do
    counter = :counters.new(1, [])

    fun = fn req ->
      :counters.add(counter, 1, 1)
      inner_fun.(req)
    end

    {fun, counter}
  end

  def flunk_paystack_request_fun do
    counter = :counters.new(1, [])

    fun = fn _req ->
      :counters.add(counter, 1, 1)
      raise "paystack should not be called"
    end

    {fun, counter}
  end

  def status_request_fun(status, body) when is_integer(status) and is_binary(body) do
    fn _req ->
      {:ok, %Req.Response{status: status, body: body}}
    end
  end

  def timeout_request_fun do
    fn _req ->
      {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  def malformed_success_request_fun do
    fn req ->
      reference = req.options.json[:reference]

      {:ok,
       %Req.Response{
         status: 200,
         body:
           Jason.encode!(%{
             status: true,
             message: "ok",
             data: %{reference: reference}
           })
       }}
    end
  end

  def verify_success_request_fun(opts \\ []) do
    fn req ->
      reference = Path.basename(req.url.path)
      provider_status = Keyword.get(opts, :provider_status, "success")
      amount = Keyword.get(opts, :amount, 12_500)
      currency = Keyword.get(opts, :currency, "ZAR")
      reference_value = verify_reference_value(opts, reference)

      data =
        %{
          status: provider_status,
          amount: amount,
          currency: currency,
          paid_at: "2026-06-17T08:00:00Z",
          email: "buyer-secret@example.com",
          authorization_url: "https://checkout.paystack.com/secret"
        }
        |> maybe_put_reference(reference_value)

      {:ok,
       %Req.Response{
         status: 200,
         body: Jason.encode!(%{status: true, message: "ok", data: data})
       }}
    end
  end

  defp verify_reference_value(opts, reference) do
    cond do
      Keyword.get(opts, :omit_reference, false) -> :omit
      Keyword.has_key?(opts, :reference) -> Keyword.get(opts, :reference)
      true -> reference
    end
  end

  defp maybe_put_reference(data, :omit), do: data

  defp maybe_put_reference(data, reference) when is_binary(reference) or is_nil(reference) do
    Map.put(data, :reference, reference)
  end

  def verify_http_error_request_fun(status, body \\ ~s({"status":false,"message":"bad"})) do
    error_fun = status_request_fun(status, body)

    fn req ->
      path = URI.parse(to_string(req.url)).path || ""

      if String.contains?(path, "/transaction/verify/") do
        error_fun.(req)
      else
        success_request_fun().(req)
      end
    end
  end

  def verify_decode_error_request_fun do
    fn req ->
      path = URI.parse(to_string(req.url)).path || ""

      if String.contains?(path, "/transaction/verify/") do
        {:ok, %Req.Response{status: 200, body: "not-json"}}
      else
        success_request_fun().(req)
      end
    end
  end

  def init_and_verify_request_fun(opts \\ []) do
    init_fun = success_request_fun(opts)
    verify_fun = verify_success_request_fun(opts)

    fn req ->
      path = URI.parse(to_string(req.url)).path || ""

      if String.contains?(path, "/transaction/verify/") do
        verify_fun.(req)
      else
        init_fun.(req)
      end
    end
  end

  def initialized_payment!(offer, opts \\ []) do
    alias FastCheck.Sales.CheckoutSession
    alias FastCheck.Sales.Order
    alias FastCheck.Sales.PaymentAttempt
    alias FastCheck.Sales.Payments.TransactionInitialization
    alias FastCheck.SalesCheckoutFixtures, as: Fixtures

    {order, session} = checkout_ready_for_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      init_and_verify_request_fun(opts)
    )

    case TransactionInitialization.initialize_for_checkout_session(
           session.id,
           Fixtures.system_actor()
         ) do
      {:ok, init_result} ->
        attempt =
          PaymentAttempt
          |> Query.for_read(:get_by_id, %{id: init_result.payment_attempt_id})
          |> Ash.read_one!(authorize?: false)

        order =
          Order
          |> Query.for_read(:get_by_id, %{id: order.id})
          |> Ash.read_one!(authorize?: false)

        session =
          CheckoutSession
          |> Query.for_read(:get_by_id, %{id: session.id})
          |> Ash.read_one!(authorize?: false)

        %{order: order, session: session, attempt: attempt, init: init_result}

      other ->
        raise "payment initialization failed: #{inspect(other)}"
    end
  end

  def insert_payment_event!(attrs \\ %{}) do
    alias Ash.Changeset
    alias FastCheck.Sales.PaymentEvent

    defaults = %{
      provider: "paystack",
      provider_event_id: "evt-#{System.unique_integer([:positive])}",
      provider_reference: "ref-#{System.unique_integer([:positive])}",
      event_type: "charge.success",
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_payload: %{"event" => "charge.success"},
      processing_status: "stored",
      processing_attempt_count: 0
    }

    attrs = Map.merge(defaults, attrs)

    PaymentEvent
    |> Changeset.for_create(:store_webhook_event, attrs)
    |> Ash.create!(authorize?: false)
  end

  def webhook_secret do
    Application.get_env(:fastcheck, :paystack_secret_key, "sk_test_fake_key")
  end

  def sign_webhook_body(body, secret \\ webhook_secret()) when is_binary(body) do
    :crypto.mac(:hmac, :sha512, secret, body)
    |> Base.encode16(case: :lower)
  end

  def charge_success_webhook_body(opts \\ []) do
    provider_event_id =
      Keyword.get(opts, :provider_event_id, "evt-#{System.unique_integer([:positive])}")

    reference = Keyword.get(opts, :reference, "ref-#{System.unique_integer([:positive])}")
    no_event_id = Keyword.get(opts, :no_event_id, false)

    payload =
      if no_event_id do
        %{
          "event" => "charge.success",
          "data" => %{"reference" => reference}
        }
      else
        %{
          "id" => provider_event_id,
          "event" => "charge.success",
          "data" => %{"reference" => reference}
        }
      end

    Jason.encode!(payload)
  end

  def flush_webhook_dedupe_keys! do
    pattern = "sales:payments:paystack:webhook:*"

    case Redix.command(FastCheck.Redix, ["KEYS", pattern]) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        _ = Redix.command(FastCheck.Redix, ["DEL" | keys])
        :ok

      _ ->
        :ok
    end
  end
end
