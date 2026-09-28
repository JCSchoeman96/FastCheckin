defmodule FastCheckWeb.Sales.PaystackCallbackController do
  use FastCheckWeb, :controller

  alias FastCheck.Payments.Paystack.Config, as: PaystackConfig
  alias FastCheck.Sales.Payments.PaymentRecovery

  @callback_page ~S"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Checking your payment | FastCheck</title>
      </head>
      <body>
        <main>
          <h1>We're checking your payment.</h1>
          <p>You can return to WhatsApp. If Paystack confirms the payment, your ticket will be processed automatically.</p>
        </main>
      </body>
    </html>
  """

  def show(conn, params) do
    case callback_reference(params) do
      {:ok, reference} ->
        _ = PaymentRecovery.enqueue_verification_by_reference(reference)

      :error ->
        :ok
    end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> html(@callback_page)
  end

  defp callback_reference(params) when is_map(params) do
    values =
      ["reference", "trxref"]
      |> Enum.filter(&Map.has_key?(params, &1))
      |> Enum.map(&Map.get(params, &1))

    with [_ | _] <- values,
         {:ok, normalized} <- normalize_references(values),
         [reference] <- Enum.uniq(normalized) do
      {:ok, reference}
    else
      _ -> :error
    end
  end

  defp callback_reference(_params), do: :error

  defp normalize_references(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, references} ->
      case PaystackConfig.normalize_reference(value) do
        {:ok, reference} -> {:cont, {:ok, [reference | references]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, references} -> {:ok, Enum.reverse(references)}
      :error -> :error
    end
  end
end
