defmodule FastCheck.Workers.IssueTicketsWorker do
  @moduledoc """
  Minimal Oban worker for retrying Sales ticket issuance.

  The worker delegates to `FastCheck.Tickets.Issuer.issue_order/2`, which remains
  the only issuance entrypoint. It does not create ticket, attendee, delivery,
  payment, scanner, or inventory records directly.
  """

  use Oban.Worker,
    queue: :ticketing,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:sales_order_id, :idempotency_key]]

  alias FastCheck.Tickets.Issuer

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    sales_order_id = normalize_id(Map.get(args, "sales_order_id"))

    opts =
      [
        correlation_id: Map.get(args, "correlation_id"),
        idempotency_key: Map.get(args, "idempotency_key")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Issuer.issue_order(sales_order_id, opts) do
      {:ok, _result} ->
        :ok

      {:error, :order_not_found} ->
        {:error, :order_not_found}

      {:error, {:manual_review_required, _reason}} ->
        :ok

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

  defp normalize_id(id), do: id
end
