defmodule FastCheck.Messaging.WhatsApp.Dedupe do
  @moduledoc """
  Redis-backed inbound WhatsApp message dedupe.
  """

  require Logger

  alias FastCheck.Observability.Correlation

  @prefix "fastcheck:whatsapp:dedupe:message:"
  @send_payment_link_prefix "fastcheck:whatsapp:dedupe:send_payment_link:"
  @send_ticket_link_prefix "fastcheck:whatsapp:dedupe:send_ticket_link:"

  @spec claim_message(String.t(), pos_integer(), atom()) ::
          {:ok, :new | :duplicate} | {:error, term()}
  def claim_message(provider_message_id, ttl_seconds, redis_name \\ FastCheck.Redix)

  def claim_message(provider_message_id, ttl_seconds, redis_name)
      when is_binary(provider_message_id) and provider_message_id != "" and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    key = key(provider_message_id)
    value = Integer.to_string(System.system_time(:millisecond))

    case redix_command(redis_name, ["SET", key, value, "NX", "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, "OK"} ->
        {:ok, :new}

      {:ok, nil} ->
        {:ok, :duplicate}

      {:error, reason} ->
        Logger.warning(
          "whatsapp_inbound_dedupe_unavailable",
          Correlation.operational_metadata(%{reason: inspect(reason)})
        )

        {:error, reason}
    end
  end

  def claim_message(_provider_message_id, _ttl_seconds, _redis_name), do: {:error, :invalid_args}

  @spec release_message(String.t(), atom()) :: :ok
  def release_message(provider_message_id, redis_name \\ FastCheck.Redix)

  def release_message(provider_message_id, redis_name)
      when is_binary(provider_message_id) and provider_message_id != "" do
    case redix_command(redis_name, ["DEL", key(provider_message_id)]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "whatsapp_inbound_dedupe_release_failed",
          Correlation.operational_metadata(%{reason: inspect(reason)})
        )

        :ok
    end
  end

  def release_message(_provider_message_id, _redis_name), do: :ok

  @spec claim_send_payment_link(integer(), integer(), pos_integer(), atom()) ::
          {:ok, :new | :duplicate} | {:error, term()}
  def claim_send_payment_link(
        conversation_id,
        order_id,
        ttl_seconds \\ outbound_ttl_seconds(),
        redis_name \\ FastCheck.Redix
      )

  def claim_send_payment_link(conversation_id, order_id, ttl_seconds, redis_name)
      when is_integer(conversation_id) and is_integer(order_id) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    claim_key(
      @send_payment_link_prefix <> "#{conversation_id}:#{order_id}",
      ttl_seconds,
      redis_name
    )
  end

  def claim_send_payment_link(_conversation_id, _order_id, _ttl_seconds, _redis_name),
    do: {:error, :invalid_args}

  @spec claim_send_ticket_link(integer(), integer(), pos_integer(), atom()) ::
          {:ok, :new | :duplicate} | {:error, term()}
  def claim_send_ticket_link(
        conversation_id,
        ticket_issue_id,
        ttl_seconds \\ outbound_ttl_seconds(),
        redis_name \\ FastCheck.Redix
      )

  def claim_send_ticket_link(conversation_id, ticket_issue_id, ttl_seconds, redis_name)
      when is_integer(conversation_id) and is_integer(ticket_issue_id) and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    claim_key(
      @send_ticket_link_prefix <> "#{conversation_id}:#{ticket_issue_id}",
      ttl_seconds,
      redis_name
    )
  end

  def claim_send_ticket_link(_conversation_id, _ticket_issue_id, _ttl_seconds, _redis_name),
    do: {:error, :invalid_args}

  defp key(provider_message_id), do: @prefix <> provider_message_id

  defp claim_key(key, ttl_seconds, redis_name) do
    value = Integer.to_string(System.system_time(:millisecond))

    case redix_command(redis_name, ["SET", key, value, "NX", "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, "OK"} -> {:ok, :new}
      {:ok, nil} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp outbound_ttl_seconds do
    Application.get_env(:fastcheck, :whatsapp_outbound_dedupe_ttl_seconds, 600)
  end

  defp redix_command(redis_name, command) do
    case Process.whereis(redis_name) do
      pid when is_pid(pid) -> Redix.command(redis_name, command)
      _ -> {:error, :redis_unavailable}
    end
  end
end
