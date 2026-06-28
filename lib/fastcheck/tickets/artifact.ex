defmodule FastCheck.Tickets.Artifact do
  @moduledoc """
  Renderer-neutral, customer-safe ticket artifact contract.

  `scanner_payload` is currently the plain scanner ticket code. Keep it
  available as normal data for valid renderers, but never expose it through
  default inspection.
  """

  @enforce_keys [
    :state,
    :event_name,
    :attendee_name,
    :ticket_type,
    :scanner_payload,
    :scanner_payload_format,
    :support_message,
    :issued_at,
    :delivery_expires_at
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :valid,
          event_name: String.t() | nil,
          attendee_name: String.t() | nil,
          ticket_type: String.t() | nil,
          scanner_payload: String.t(),
          scanner_payload_format: :plain_ticket_code,
          support_message: String.t(),
          issued_at: DateTime.t() | nil,
          delivery_expires_at: DateTime.t() | nil
        }
end

defimpl Inspect, for: FastCheck.Tickets.Artifact do
  def inspect(artifact, opts) do
    %{
      state: artifact.state,
      scanner_payload: "[REDACTED]",
      scanner_payload_format: artifact.scanner_payload_format,
      issued_at?: not is_nil(artifact.issued_at),
      delivery_expires_at?: not is_nil(artifact.delivery_expires_at)
    }
    |> Inspect.Map.inspect(opts)
  end
end
