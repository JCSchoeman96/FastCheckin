defmodule FastCheck.Workers.RefundInventoryWorker do
  @moduledoc """
  Resolves refunded order inventory from durable refund and order facts.

  The job carries only `refund_id`; the worker reloads all inventory authority.
  """

  use Oban.Worker,
    queue: :sales_inventory,
    max_attempts: 5,
    unique: [period: 300, fields: [:args, :worker], keys: [:refund_id]]

  alias FastCheck.Sales.RefundInventory

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case normalize_id(Map.get(args, "refund_id")) do
      refund_id when is_integer(refund_id) and refund_id > 0 ->
        handle_result(RefundInventory.resolve(refund_id), refund_id, job)

      _invalid_id ->
        {:discard, :invalid_refund_id}
    end
  end

  defp handle_result({:ok, _refund}, _refund_id, _job), do: :ok

  defp handle_result({:error, {:retryable_inventory, reason}}, refund_id, job) do
    if final_attempt?(job) do
      case RefundInventory.mark_inventory_manual_review(refund_id, "inventory_retry_exhausted") do
        {:ok, _refund} -> :ok
        {:error, error} -> {:error, {:inventory_manual_review_failed, error}}
      end
    else
      {:error, {:refund_inventory_retryable, reason}}
    end
  end

  defp handle_result({:error, :refund_not_found}, _refund_id, _job),
    do: {:discard, :refund_not_found}

  defp handle_result({:error, reason}, _refund_id, _job), do: {:error, reason}

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp final_attempt?(_job), do: false

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_id(_id), do: nil
end
