defmodule FastCheck.Payments.Paystack.EventDedupe do
  @moduledoc """
  Redis SETNX dedupe for Paystack webhook deliveries.
  """

  require Logger

  alias FastCheck.Observability.Correlation

  @dedupe_prefix "sales:payments:paystack:webhook:"
  @ttl_seconds 86_400

  @spec claim(String.t()) :: :ok | {:error, :duplicate} | {:error, :redis_unavailable}
  def claim(dedupe_key) when is_binary(dedupe_key) and dedupe_key != "" do
    redis_key = @dedupe_prefix <> dedupe_key
    value = Integer.to_string(System.system_time(:millisecond))

    case redix_command(["SET", redis_key, value, "NX", "EX", Integer.to_string(@ttl_seconds)]) do
      {:ok, "OK"} ->
        :ok

      {:ok, nil} ->
        {:error, :duplicate}

      {:error, reason} ->
        Logger.warning(
          "paystack_webhook_redis_dedupe_unavailable",
          Correlation.operational_metadata(%{reason: inspect(reason)})
        )

        {:error, :redis_unavailable}
    end
  end

  def claim(_), do: :ok

  @spec release(String.t()) :: :ok
  def release(dedupe_key) when is_binary(dedupe_key) and dedupe_key != "" do
    redis_key = @dedupe_prefix <> dedupe_key

    case redix_command(["DEL", redis_key]) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  def release(_), do: :ok

  @spec dedupe_key(String.t() | nil, String.t()) :: String.t()
  def dedupe_key(provider_event_id, payload_hash)
      when is_binary(payload_hash) and payload_hash != "" do
    if is_binary(provider_event_id) and provider_event_id != "" do
      provider_event_id
    else
      payload_hash
    end
  end

  defp redix_command(command) do
    case Process.whereis(FastCheck.Redix) do
      pid when is_pid(pid) -> Redix.command(FastCheck.Redix, command)
      _ -> {:error, :redis_unavailable}
    end
  end
end
