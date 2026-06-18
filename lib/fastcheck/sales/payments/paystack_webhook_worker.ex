defmodule FastCheck.Sales.Payments.PaystackWebhookWorker do
  @moduledoc """
  Oban worker shell for Paystack webhook ingestion.

  VS-07A loads the stored `PaymentEvent` and emits telemetry only. Transaction
  verification and payment state mutation belong to VS-07B+.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:payment_event_id]]

  alias FastCheck.Observability.Correlation
  alias FastCheck.Sales.PaymentEvent

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payment_event_id" => payment_event_id}}) do
    payment_event_id = normalize_id(payment_event_id)

    with {:ok, event} <- load_event(payment_event_id) do
      metadata =
        Correlation.operational_metadata(%{
          payment_event_id: event.id,
          provider: event.provider,
          event_type: event.event_type,
          status: event.processing_status
        })
        |> Map.new()

      :telemetry.execute(
        [:fastcheck, :sales, :payment, :webhook_received],
        %{count: 1},
        metadata
      )

      :ok
    end
  end

  def perform(_job), do: {:error, :invalid_args}

  defp load_event(payment_event_id) do
    require Ash.Query
    import Ash.Expr

    PaymentEvent
    |> Ash.Query.filter(expr(id == ^payment_event_id))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :payment_event_not_found}
      {:ok, event} -> {:ok, event}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
end
