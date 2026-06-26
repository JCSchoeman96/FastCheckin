defmodule FastCheck.Messaging.WhatsApp.InboundNormalizer do
  @moduledoc """
  Normalizes signed Meta WhatsApp webhook payloads into safe message commands.
  """

  alias FastCheck.Messaging.WhatsApp.MessageCommand
  alias FastCheck.Observability.Correlation

  @max_text_body 1_024

  @spec normalize(map(), keyword()) :: {:ok, [MessageCommand.t()]} | {:error, :malformed_payload}
  def normalize(payload, opts \\ [])

  def normalize(payload, opts) when is_map(payload) do
    raw_payload_hash = Keyword.get(opts, :raw_payload_hash)

    correlation_id =
      Correlation.ensure_correlation_id(%{correlation_id: Keyword.get(opts, :correlation_id)})

    commands =
      payload
      |> message_values()
      |> Enum.flat_map(fn value ->
        contacts_by_wa_id = contacts_by_wa_id(value)

        value
        |> Map.get("messages", [])
        |> Enum.map(
          &command_from_message(&1, contacts_by_wa_id, raw_payload_hash, correlation_id)
        )
        |> Enum.reject(&is_nil/1)
      end)

    {:ok, commands}
  rescue
    _ -> {:error, :malformed_payload}
  end

  def normalize(_payload, _opts), do: {:error, :malformed_payload}

  defp message_values(payload) do
    payload
    |> Map.get("entry", [])
    |> List.wrap()
    |> Enum.flat_map(&Map.get(&1, "changes", []))
    |> Enum.map(&Map.get(&1, "value", %{}))
    |> Enum.filter(&is_map/1)
  end

  defp contacts_by_wa_id(value) do
    value
    |> Map.get("contacts", [])
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Map.new(fn contact -> {Map.get(contact, "wa_id"), contact} end)
  end

  defp command_from_message(message, contacts_by_wa_id, raw_payload_hash, correlation_id)
       when is_map(message) do
    with id when is_binary(id) and id != "" <- Map.get(message, "id"),
         wa_id when is_binary(wa_id) and wa_id != "" <- Map.get(message, "from"),
         phone_e164 when is_binary(phone_e164) <- phone_e164(wa_id, contacts_by_wa_id) do
      message_type = normalize_message_type(Map.get(message, "type"))

      %MessageCommand{
        provider: "meta",
        provider_message_id: id,
        phone_e164: phone_e164,
        wa_id: wa_id,
        message_type: message_type,
        text_body: text_body(message, message_type),
        interactive_payload: interactive_payload(message, message_type),
        received_at: received_at(message),
        raw_payload_hash: raw_payload_hash || "",
        correlation_id: correlation_id,
        metadata: %{}
      }
    else
      _ -> nil
    end
  end

  defp command_from_message(_message, _contacts, _hash, _correlation_id), do: nil

  defp phone_e164(wa_id, contacts_by_wa_id) do
    contact_wa_id =
      contacts_by_wa_id
      |> Map.get(wa_id, %{})
      |> Map.get("wa_id", wa_id)

    normalized = "+" <> String.trim_leading(contact_wa_id, "+")

    if Regex.match?(~r/^\+[1-9][0-9]{7,14}$/, normalized), do: normalized, else: nil
  end

  defp normalize_message_type(type) when type in ["text", "interactive", "button"], do: type
  defp normalize_message_type(_type), do: "unknown"

  defp text_body(%{"text" => %{"body" => body}}, "text") when is_binary(body) do
    body
    |> String.trim()
    |> String.slice(0, @max_text_body)
  end

  defp text_body(_message, _message_type), do: nil

  defp interactive_payload(%{"interactive" => payload}, "interactive") when is_map(payload),
    do: payload

  defp interactive_payload(%{"button" => payload}, "button") when is_map(payload), do: payload
  defp interactive_payload(_message, _message_type), do: %{}

  defp received_at(%{"timestamp" => timestamp}) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {unix, ""} -> DateTime.from_unix!(unix)
      _ -> DateTime.utc_now()
    end
    |> DateTime.truncate(:second)
  end

  defp received_at(_message), do: DateTime.utc_now() |> DateTime.truncate(:second)
end
