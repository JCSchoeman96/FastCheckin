defmodule FastCheck.Messaging.WhatsApp.Dedupe do
  @moduledoc """
  Redis-backed inbound WhatsApp message dedupe.
  """

  require Logger

  alias FastCheck.Observability.Correlation

  @prefix "fastcheck:whatsapp:dedupe:message:"

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

  defp key(provider_message_id), do: @prefix <> provider_message_id

  defp redix_command(redis_name, command) do
    case Process.whereis(redis_name) do
      pid when is_pid(pid) -> Redix.command(redis_name, command)
      _ -> {:error, :redis_unavailable}
    end
  end
end
