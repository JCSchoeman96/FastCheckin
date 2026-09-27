defmodule FastCheck.Workers.PaidOrderFulfillmentWorker do
  @moduledoc """
  Consumes inventory and starts ticket issuance for a verified payment attempt.
  """

  use Oban.Worker,
    queue: :sales_inventory,
    max_attempts: 5,
    unique: [period: 300, fields: [:args, :worker], keys: [:payment_attempt_id]]

  alias FastCheck.Sales.PaidOrderFulfillment

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case normalize_id(Map.get(args, "payment_attempt_id")) do
      payment_attempt_id when is_integer(payment_attempt_id) and payment_attempt_id > 0 ->
        opts = [
          correlation_id: Map.get(args, "correlation_id"),
          attempt: job.attempt,
          max_attempts: job.max_attempts
        ]

        case PaidOrderFulfillment.fulfill(payment_attempt_id, opts) do
          {:ok, _result} -> :ok
          {:error, :payment_attempt_not_found} -> {:discard, :payment_attempt_not_found}
          {:error, :payment_not_verified} -> {:discard, :payment_not_verified}
          {:error, :invalid_order_state} -> {:discard, :invalid_order_state}
          {:error, reason} -> {:error, reason}
        end

      _invalid_id ->
        {:discard, :invalid_payment_attempt_id}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_id(_id), do: nil
end
