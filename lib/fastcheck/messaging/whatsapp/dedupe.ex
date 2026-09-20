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

  @spec release_send_payment_link(integer(), integer(), atom()) :: :ok
  def release_send_payment_link(conversation_id, order_id, redis_name \\ FastCheck.Redix)

  def release_send_payment_link(conversation_id, order_id, redis_name)
      when is_integer(conversation_id) and is_integer(order_id) do
    release_key(
      @send_payment_link_prefix <> "#{conversation_id}:#{order_id}",
      "whatsapp_payment_link_dedupe_release_failed",
      redis_name
    )
  end

  def release_send_payment_link(_conversation_id, _order_id, _redis_name), do: :ok

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
      send_ticket_link_identity(conversation_id, ticket_issue_id),
      ttl_seconds,
      redis_name
    )
  end

  def claim_send_ticket_link(_conversation_id, _ticket_issue_id, _ttl_seconds, _redis_name),
    do: {:error, :invalid_args}

  @spec claim_send_ticket_link_for_challenge(
          integer(),
          integer(),
          integer(),
          pos_integer(),
          atom()
        ) ::
          {:ok, :new | :duplicate} | {:error, term()}
  def claim_send_ticket_link_for_challenge(
        conversation_id,
        ticket_issue_id,
        ticket_resend_challenge_id,
        ttl_seconds,
        redis_name
      )
      when is_integer(conversation_id) and is_integer(ticket_issue_id) and
             is_integer(ticket_resend_challenge_id) and is_integer(ttl_seconds) and
             ttl_seconds > 0 do
    claim_key(
      send_ticket_link_identity(conversation_id, ticket_issue_id, ticket_resend_challenge_id),
      ttl_seconds,
      redis_name
    )
  end

  def claim_send_ticket_link_for_challenge(
        _conversation_id,
        _ticket_issue_id,
        _ticket_resend_challenge_id,
        _ttl_seconds,
        _redis_name
      ),
      do: {:error, :invalid_args}

  @spec release_send_ticket_link(integer(), integer(), atom()) :: :ok
  def release_send_ticket_link(conversation_id, ticket_issue_id, redis_name \\ FastCheck.Redix)

  def release_send_ticket_link(conversation_id, ticket_issue_id, redis_name)
      when is_integer(conversation_id) and is_integer(ticket_issue_id) do
    release_key(
      send_ticket_link_identity(conversation_id, ticket_issue_id),
      "whatsapp_ticket_link_dedupe_release_failed",
      redis_name
    )
  end

  def release_send_ticket_link(_conversation_id, _ticket_issue_id, _redis_name), do: :ok

  @spec release_send_ticket_link_for_challenge(integer(), integer(), integer(), atom()) :: :ok
  def release_send_ticket_link_for_challenge(
        conversation_id,
        ticket_issue_id,
        ticket_resend_challenge_id,
        redis_name
      )
      when is_integer(conversation_id) and is_integer(ticket_issue_id) and
             is_integer(ticket_resend_challenge_id) do
    release_key(
      send_ticket_link_identity(conversation_id, ticket_issue_id, ticket_resend_challenge_id),
      "whatsapp_ticket_link_dedupe_release_failed",
      redis_name
    )
  end

  def release_send_ticket_link_for_challenge(
        _conversation_id,
        _ticket_issue_id,
        _ticket_resend_challenge_id,
        _redis_name
      ),
      do: :ok

  @spec send_ticket_link_identity(integer(), integer(), integer() | nil) :: String.t()
  def send_ticket_link_identity(
        conversation_id,
        ticket_issue_id,
        ticket_resend_challenge_id \\ nil
      )

  def send_ticket_link_identity(conversation_id, ticket_issue_id, nil),
    do: @send_ticket_link_prefix <> "#{conversation_id}:#{ticket_issue_id}"

  def send_ticket_link_identity(conversation_id, ticket_issue_id, ticket_resend_challenge_id)
      when is_integer(conversation_id) and is_integer(ticket_issue_id) and
             is_integer(ticket_resend_challenge_id) do
    @send_ticket_link_prefix <>
      "#{conversation_id}:#{ticket_issue_id}:challenge:#{ticket_resend_challenge_id}"
  end

  defp key(provider_message_id), do: @prefix <> provider_message_id

  defp claim_key(key, ttl_seconds, redis_name) do
    value = Integer.to_string(System.system_time(:millisecond))

    case redix_command(redis_name, ["SET", key, value, "NX", "EX", Integer.to_string(ttl_seconds)]) do
      {:ok, "OK"} -> {:ok, :new}
      {:ok, nil} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_key(key, event_name, redis_name) do
    case redix_command(redis_name, ["DEL", key]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          event_name,
          Correlation.operational_metadata(%{reason: inspect(reason)})
        )

        :ok
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
