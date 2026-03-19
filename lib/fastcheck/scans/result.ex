defmodule FastCheck.Scans.Result do
  @moduledoc """
  Internal representation of a mobile scan ingestion outcome.
  """

  @enforce_keys [
    :event_id,
    :idempotency_key,
    :ticket_code,
    :direction,
    :status,
    :reason_code,
    :message,
    :processed_at,
    :delivery_state,
    :hot_state_version
  ]
  defstruct [
    :event_id,
    :attendee_id,
    :idempotency_key,
    :ticket_code,
    :direction,
    :status,
    :reason_code,
    :message,
    :entrance_name,
    :operator_name,
    :scanned_at,
    :processed_at,
    :delivery_state,
    :hot_state_version,
    metadata: %{}
  ]

  @type delivery_state :: :new_staged | :pending_durability | :final_acknowledged

  @type t :: %__MODULE__{
          event_id: integer(),
          attendee_id: integer() | nil,
          idempotency_key: String.t(),
          ticket_code: String.t(),
          direction: String.t(),
          status: String.t(),
          reason_code: String.t(),
          message: String.t(),
          entrance_name: String.t() | nil,
          operator_name: String.t() | nil,
          scanned_at: DateTime.t() | nil,
          processed_at: DateTime.t(),
          delivery_state: delivery_state(),
          hot_state_version: String.t(),
          metadata: map()
        }

  @spec to_api_result(t()) :: map()
  def to_api_result(%__MODULE__{} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: result.status,
      message: result.message
    }
  end

  @spec to_duplicate_api_result(t()) :: map()
  def to_duplicate_api_result(%__MODULE__{} = result) do
    %{
      idempotency_key: result.idempotency_key,
      status: "duplicate",
      message: duplicate_message(result)
    }
  end

  defp duplicate_message(%__MODULE__{message: message})
       when is_binary(message) and message != "" do
    "Already processed: #{message}"
  end

  defp duplicate_message(_result), do: "Already processed"
end
