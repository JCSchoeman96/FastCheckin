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
          safe_metadata: map()
        }
end

defimpl Inspect, for: FastCheck.Messaging.WhatsApp.Response do
  alias FastCheck.Messaging.WhatsApp.Response

  def inspect(%Response{} = response, opts) do
    response
    |> Map.from_struct()
    |> Map.update!(:provider_error_message, &safe_message/1)
    |> Inspect.Map.inspect(opts)
  end

  defp safe_message(nil), do: nil
  defp safe_message(_), do: "meta request failed"
end
