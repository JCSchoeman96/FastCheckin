defmodule FastCheck.Messaging.WhatsApp.Response do
  @moduledoc """
  Normalized safe response shape for Meta WhatsApp provider-boundary calls.
  """

  @enforce_keys [:provider, :status]
  defstruct [
    :provider,
    :provider_message_id,
    :status,
    :raw_status,
    :provider_status,
    :provider_error_code,
    :provider_error_message,
    retryable?: false,
    rate_limited?: false,
    ambiguous?: false,
    safe_metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: :meta,
          provider_message_id: String.t() | nil,
          status: atom(),
          raw_status: integer() | nil,
          provider_status: String.t() | nil,
          provider_error_code: String.t() | nil,
          provider_error_message: String.t() | nil,
          retryable?: boolean(),
          rate_limited?: boolean(),
          ambiguous?: boolean(),
          safe_metadata: map()
        }
end

defimpl Inspect, for: FastCheck.Messaging.WhatsApp.Response do
  alias FastCheck.Messaging.WhatsApp.Response
  alias FastCheck.Observability.Redactor

  def inspect(%Response{} = response, opts) do
    response
    |> Map.from_struct()
    |> Map.update!(:provider_message_id, &redact_provider_message_id/1)
    |> Map.update!(:provider_error_message, &safe_message/1)
    |> Inspect.Map.inspect(opts)
  end

  defp redact_provider_message_id(nil), do: nil
  defp redact_provider_message_id(_), do: Redactor.filtered()

  defp safe_message(nil), do: nil
  defp safe_message(_), do: "meta request failed"
end
