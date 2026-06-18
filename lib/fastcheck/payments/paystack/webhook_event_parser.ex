defmodule FastCheck.Payments.Paystack.WebhookEventParser do
  @moduledoc """
  Pure Paystack webhook payload metadata extraction for Sales ingestion.
  """

  @type metadata :: %{
          provider_event_id: String.t() | nil,
          provider_reference: String.t() | nil,
          event_type: String.t()
        }

  @spec parse(map()) :: {:ok, metadata()} | {:error, :missing_event_type}
  def parse(payload) when is_map(payload) do
    event_type = Map.get(payload, "event") || Map.get(payload, :event)

    if is_binary(event_type) and event_type != "" do
      {:ok,
       %{
         provider_event_id: provider_event_id(payload),
         provider_reference: provider_reference(payload),
         event_type: event_type
       }}
    else
      {:error, :missing_event_type}
    end
  end

  def parse(_), do: {:error, :missing_event_type}

  defp provider_event_id(payload) do
    id = Map.get(payload, "id") || Map.get(payload, "event_id")

    case id do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp provider_reference(payload) do
    data = Map.get(payload, "data", %{})

    case Map.get(data, "reference") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
