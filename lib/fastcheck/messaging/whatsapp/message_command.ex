defmodule FastCheck.Messaging.WhatsApp.MessageCommand do
  @moduledoc """
  Bounded internal representation of a signed inbound WhatsApp message.
  """

  alias FastCheck.Observability.Redactor

  @enforce_keys [
    :provider,
    :provider_message_id,
    :phone_e164,
    :wa_id,
    :message_type,
    :received_at,
    :raw_payload_hash,
    :correlation_id
  ]

  defstruct [
    :provider,
    :provider_message_id,
    :phone_e164,
    :wa_id,
    :message_type,
    :text_body,
    :interactive_payload,
    :received_at,
    :raw_payload_hash,
    :correlation_id,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          provider: String.t(),
          provider_message_id: String.t(),
          phone_e164: String.t(),
          wa_id: String.t(),
          message_type: String.t(),
          text_body: String.t() | nil,
          interactive_payload: map() | nil,
          received_at: DateTime.t(),
          raw_payload_hash: String.t(),
          correlation_id: String.t(),
          metadata: map()
        }

  @doc false
  def safe_summary(%__MODULE__{} = command) do
    %{
      provider: command.provider,
      provider_message_id_hash: hash_id(command.provider_message_id),
      phone_e164: Redactor.redact_phone(command.phone_e164),
      wa_id_hash: hash_id(command.wa_id),
      message_type: command.message_type,
      text_body: if(is_binary(command.text_body), do: Redactor.filtered_message(), else: nil),
      raw_payload_hash: command.raw_payload_hash,
      correlation_id: command.correlation_id
    }
  end

  defp hash_id(nil), do: nil

  defp hash_id(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end
end

defimpl Inspect, for: FastCheck.Messaging.WhatsApp.MessageCommand do
  alias FastCheck.Messaging.WhatsApp.MessageCommand

  def inspect(%MessageCommand{} = command, opts) do
    command
    |> MessageCommand.safe_summary()
    |> Inspect.Map.inspect(opts)
  end
end
