defmodule FastCheck.Ticketing.EventConfigCache do
  @moduledoc """
  Short-lived Redis-backed event config cache for native scanner bootstrap and
  health requests.
  """

  alias FastCheck.Redis

  @spec get(integer()) :: {:ok, map() | nil} | {:error, term()}
  def get(event_id) when is_integer(event_id) do
    case Redis.command(["GET", cache_key(event_id)]) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, payload} when is_binary(payload) ->
        case Jason.decode(payload) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, reason}
        end

      other ->
        other
    end
  end

  def get(_event_id), do: {:error, :invalid_event_id}

  @spec put(integer(), map()) :: :ok | {:error, term()}
  def put(event_id, payload) when is_integer(event_id) and is_map(payload) do
    ttl_seconds = Application.get_env(:fastcheck, :event_config_cache_ttl_seconds, 60)

    case Jason.encode(payload) do
      {:ok, encoded} ->
        case Redis.command([
               "SETEX",
               cache_key(event_id),
               Integer.to_string(ttl_seconds),
               encoded
             ]) do
          {:ok, _value} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def put(_event_id, _payload), do: {:error, :invalid_payload}

  @spec invalidate(integer()) :: :ok | {:error, term()}
  def invalidate(event_id) when is_integer(event_id) do
    case Redis.command(["DEL", cache_key(event_id)]) do
      {:ok, _value} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def invalidate(_event_id), do: {:error, :invalid_event_id}

  @spec cache_key(integer()) :: String.t()
  def cache_key(event_id), do: "event_config:#{event_id}"
end
