defmodule FastCheck.Redis.Namespace do
  @moduledoc """
  Builds Redis keys and scan patterns within the configured application scope.

  Production keeps the legacy key names when `:redis_namespace` is unset. DEV,
  TEST, and explicitly configured production deployments can set a namespace to
  isolate their keys from other FastCheck processes sharing the Redis server.
  """

  @app :fastcheck
  @config_key :redis_namespace

  @single_key_commands [
    "GET",
    "SET",
    "SETEX",
    "SETNX",
    "GETSET",
    "EXISTS",
    "TTL",
    "PTTL",
    "HGETALL",
    "HGET",
    "HSET",
    "HMGET",
    "HMSET",
    "EXPIRE",
    "PEXPIRE",
    "SADD",
    "SISMEMBER",
    "SMEMBERS",
    "SCARD",
    "ZADD",
    "ZRANGE",
    "ZRANGEBYSCORE",
    "ZREM",
    "INCR",
    "INCRBY",
    "DECR",
    "DECRBY"
  ]

  @prohibited_commands ["FLUSHALL", "FLUSHDB"]

  @doc "Returns the configured Redis namespace, or `nil` for legacy keys."
  @spec namespace() :: String.t() | nil
  def namespace do
    case Application.get_env(@app, @config_key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value ->
        value |> to_string() |> String.trim() |> blank_to_nil()
    end
  end

  @doc "Prefixes a Redis key once when a namespace is configured."
  @spec key(String.t()) :: String.t()
  def key(raw_key) when is_binary(raw_key) do
    scope(raw_key)
  end

  @doc "Prefixes a Redis `SCAN MATCH` pattern once when a namespace is configured."
  @spec pattern(String.t()) :: String.t()
  def pattern(raw_pattern) when is_binary(raw_pattern) do
    scope(raw_pattern)
  end

  @doc "Removes the configured namespace from a key before parsing its logical parts."
  @spec unscoped(String.t()) :: String.t()
  def unscoped(key) when is_binary(key) do
    case namespace() do
      nil -> key
      namespace -> String.trim_leading(key, namespace <> ":")
    end
  end

  @doc "Returns whether a key belongs to the configured namespace."
  @spec scoped?(String.t()) :: boolean()
  def scoped?(key) when is_binary(key) do
    case namespace() do
      nil -> true
      namespace -> key == namespace or String.starts_with?(key, namespace <> ":")
    end
  end

  @doc "Raises unless every key belongs to the configured namespace."
  @spec ensure_scoped_keys!([String.t()]) :: [String.t()]
  def ensure_scoped_keys!(keys) when is_list(keys) do
    case Enum.find(keys, &(not scoped?(&1))) do
      nil -> keys
      key -> raise ArgumentError, "Redis key is outside the configured namespace: #{inspect(key)}"
    end
  end

  @doc "Scopes key arguments for the small generic Redis wrapper."
  @spec command([term()]) :: [term()]
  def command([command | _rest] = arguments) when is_binary(command) do
    if String.upcase(command) in @prohibited_commands do
      raise ArgumentError, "Redis FLUSHALL and FLUSHDB commands are prohibited"
    end

    scope_command(arguments)
  end

  def command(command), do: command

  defp scope_command(["DEL" | keys]), do: ["DEL" | Enum.map(keys, &key/1)]

  defp scope_command(["KEYS", match]), do: ["KEYS", pattern(match)]

  defp scope_command([command, key | rest]) when command in @single_key_commands,
    do: [command, key(key) | rest]

  defp scope_command(["SCAN", cursor, "MATCH", match | rest]),
    do: ["SCAN", cursor, "MATCH", pattern(match) | rest]

  defp scope_command(command), do: command

  defp scope(raw_key) do
    case namespace() do
      nil ->
        raw_key

      namespace ->
        if raw_key == namespace or String.starts_with?(raw_key, namespace <> ":") do
          raw_key
        else
          namespace <> ":" <> raw_key
        end
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
