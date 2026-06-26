defmodule FastCheck.Messaging.WhatsApp.SessionStore do
  @moduledoc """
  Redis hot session state for inbound WhatsApp conversations.
  """

  alias FastCheck.Messaging.WhatsApp.MessageCommand

  @prefix "fastcheck:whatsapp:session:"

  @spec put_session(MessageCommand.t(), map(), pos_integer()) :: :ok | {:error, term()}
  def put_session(%MessageCommand{} = command, conversation, ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds > 0 do
    fields = fields(command, conversation, %{})

    with :ok <- write_hash(key_for_wa_id(command.wa_id), fields, ttl_seconds) do
      write_hash(key_for_phone(command.phone_e164), fields, ttl_seconds)
    end
  end

  def put_session(_command, _conversation, _ttl_seconds), do: {:error, :invalid_args}

  @spec put_flow_session(MessageCommand.t(), map(), map(), pos_integer()) ::
          :ok | {:error, term()}
  def put_flow_session(%MessageCommand{} = command, conversation, flow_fields, ttl_seconds)
      when is_map(flow_fields) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    fields = fields(command, conversation, flow_fields)

    with :ok <- write_hash(key_for_wa_id(command.wa_id), fields, ttl_seconds) do
      write_hash(key_for_phone(command.phone_e164), fields, ttl_seconds)
    end
  end

  def put_flow_session(_command, _conversation, _flow_fields, _ttl_seconds),
    do: {:error, :invalid_args}

  @spec get_session_by_wa_id(String.t()) :: {:ok, map()} | {:error, term()}
  def get_session_by_wa_id(wa_id) when is_binary(wa_id) do
    case Redix.command(FastCheck.Redix, ["HGETALL", key_for_wa_id(wa_id)]) do
      {:ok, []} -> {:error, :not_found}
      {:ok, values} -> {:ok, redis_values_to_map(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_session_by_wa_id(_wa_id), do: {:error, :invalid_args}

  @spec key_for_wa_id(String.t()) :: String.t()
  def key_for_wa_id(wa_id) when is_binary(wa_id), do: @prefix <> "wa:" <> hash(wa_id)

  @spec key_for_phone(String.t()) :: String.t()
  def key_for_phone(phone_e164) when is_binary(phone_e164),
    do: @prefix <> "phone:" <> hash(phone_e164)

  defp write_hash(key, fields, ttl_seconds) do
    commands = [
      ["HSET", key | fields],
      ["EXPIRE", key, Integer.to_string(ttl_seconds)]
    ]

    case Redix.pipeline(FastCheck.Redix, commands) do
      {:ok, [_hset, 1]} -> :ok
      {:ok, [_hset, 0]} -> {:error, :ttl_not_set}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fields(command, conversation, flow_fields) do
    expires_at = datetime_to_iso(Map.get(conversation, :expires_at))

    %{
      "wa_id_hash" => hash(command.wa_id),
      "phone_e164_redacted" => FastCheck.Observability.Redactor.redact_phone(command.phone_e164),
      "conversation_id" => Map.get(conversation, :id),
      "state" => Map.get(conversation, :state, "new"),
      "preferred_language" => Map.get(conversation, :preferred_language, "af"),
      "last_provider_message_id" => command.provider_message_id,
      "last_message_at" => datetime_to_iso(command.received_at),
      "expires_at" => expires_at,
      "needs_human" => Map.get(conversation, :needs_human, false),
      "handoff_reason" => Map.get(conversation, :handoff_reason),
      "correlation_id" => command.correlation_id
    }
    |> Map.merge(safe_flow_fields(flow_fields))
    |> Enum.flat_map(fn {key, value} -> [key, value_to_redis(value)] end)
  end

  defp safe_flow_fields(flow_fields) do
    allowed = [
      :selected_event_id,
      :selected_offer_id,
      :quantity,
      :sales_order_id,
      :order_public_reference,
      :version
    ]

    flow_fields
    |> Map.take(allowed ++ Enum.map(allowed, &Atom.to_string/1))
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp redis_values_to_map(values) do
    values
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {key, value} end)
  end

  defp datetime_to_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_iso(_), do: nil

  defp value_to_redis(nil), do: ""
  defp value_to_redis(value) when is_binary(value), do: value
  defp value_to_redis(value) when is_boolean(value), do: to_string(value)
  defp value_to_redis(value), do: to_string(value)

  defp hash(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
