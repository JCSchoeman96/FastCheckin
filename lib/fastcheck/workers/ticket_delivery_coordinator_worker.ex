defmodule FastCheck.Workers.TicketDeliveryCoordinatorWorker do
  @moduledoc """
  Durable handoff from complete WhatsApp ticket issuance to ticket delivery intents.
  """

  use Oban.Worker,
    queue: :ticketing,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:args, :worker], keys: [:sales_order_id]]

  alias FastCheck.Sales.TicketDeliveryCoordinator

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sales_order_id" => order_id} = args}) when map_size(args) == 1 do
    case TicketDeliveryCoordinator.coordinate(normalize_id(order_id)) do
      {:ok, _result} -> :ok
      {:error, :order_not_found} -> {:discard, :order_not_found}
      {:error, :invalid_order_id} -> {:discard, :invalid_order_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}

  defp normalize_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp normalize_id(_id), do: nil
end
