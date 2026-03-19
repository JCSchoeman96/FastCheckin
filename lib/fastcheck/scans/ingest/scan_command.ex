defmodule FastCheck.Scans.Ingest.ScanCommand do
  @moduledoc """
  Validated mobile scan command used by the ingestion service.
  """

  @enforce_keys [:event_id, :idempotency_key, :ticket_code, :direction]
  defstruct [
    :event_id,
    :idempotency_key,
    :ticket_code,
    :direction,
    :entrance_name,
    :operator_name,
    :scanned_at
  ]

  @type t :: %__MODULE__{
          event_id: integer(),
          idempotency_key: String.t(),
          ticket_code: String.t(),
          direction: String.t(),
          entrance_name: String.t() | nil,
          operator_name: String.t() | nil,
          scanned_at: DateTime.t() | nil
        }
end
