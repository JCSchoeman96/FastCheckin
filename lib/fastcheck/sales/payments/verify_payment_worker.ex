defmodule FastCheck.Sales.Payments.VerifyPaymentWorker do
  @moduledoc """
  Oban worker for server-side Paystack payment verification.

  Delegates to `FastCheck.Sales.Payments.PaymentVerification`; does not call
  Paystack HTTP directly or mutate ticket/inventory state.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:payment_attempt_id]]

  alias FastCheck.Sales.Payments.PaymentVerification

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    payment_attempt_id = normalize_id(Map.get(args, "payment_attempt_id"))
    payment_event_id = normalize_optional_id(Map.get(args, "payment_event_id"))

    opts =
      [payment_event_id: payment_event_id]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case PaymentVerification.verify_attempt(payment_attempt_id, opts) do
      {:ok, _} ->
        :ok

      {:error, :retryable} ->
        {:error, :retryable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp normalize_optional_id(nil), do: nil
  defp normalize_optional_id(id), do: normalize_id(id)
end
