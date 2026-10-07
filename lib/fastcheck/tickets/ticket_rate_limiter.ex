defmodule FastCheck.Tickets.TicketRateLimiter do
  @moduledoc """
  Distributed Redis sliding-window limits for P1-E `POST /t/session` exchange.

  Uses Redis `TIME` and atomic Lua per ZSET bucket. Fails closed when Redis is
  unavailable (no ETS fallback).
  """

  alias FastCheck.Redis.Namespace

  @window_seconds 60
  @exchange_token_limit 5
  @exchange_ip_limit 600
  @credential_prefix "secure-ticket-rate-limit:v1:"
  @key_ttl_seconds @window_seconds * 2

  @lua_script """
  local key = KEYS[1]
  local window_sec = tonumber(ARGV[1])
  local limit = tonumber(ARGV[2])
  local nonce = ARGV[3]
  local key_ttl = tonumber(ARGV[4])

  local t = redis.call('TIME')
  local now_usec = tonumber(t[1]) * 1000000 + tonumber(t[2])
  local window_usec = window_sec * 1000000
  local window_start = now_usec - window_usec

  redis.call('ZREMRANGEBYSCORE', key, '-inf', window_start)
  local count = redis.call('ZCARD', key)

  if count < limit then
    local member = tostring(now_usec) .. ':' .. nonce
    redis.call('ZADD', key, now_usec, member)
    redis.call('EXPIRE', key, key_ttl)
    return {1, count + 1, 0}
  else
    local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
    local retry_after = window_sec
    if oldest[2] then
      local oldest_score = tonumber(oldest[2])
      local remaining_usec = oldest_score + window_usec - now_usec
      retry_after = math.ceil(remaining_usec / 1000000)
      if retry_after < 1 then
        retry_after = 1
      end
    end
    redis.call('EXPIRE', key, key_ttl)
    return {0, count, retry_after}
  end
  """

  @type check_result ::
          :allowed
          | {:rate_limited, retry_after :: pos_integer()}
          | :unavailable

  @doc """
  Applies exchange token and trusted-IP buckets for one delivery bearer attempt.

  Never logs or stores the raw bearer.
  """
  @spec check_exchange(String.t(), String.t(), keyword()) :: check_result()
  def check_exchange(delivery_token, client_ip, opts \\ [])
      when is_binary(delivery_token) and is_binary(client_ip) do
    redix_name = Keyword.get(opts, :redix_name, FastCheck.Redix)

    case check_bucket(token_key(delivery_token), @exchange_token_limit, redix_name) do
      :allowed ->
        check_bucket(ip_key(client_ip), @exchange_ip_limit, redix_name)

      other ->
        other
    end
  end

  @doc false
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc false
  @spec exchange_token_limit() :: pos_integer()
  def exchange_token_limit, do: @exchange_token_limit

  @doc false
  @spec exchange_ip_limit() :: pos_integer()
  def exchange_ip_limit, do: @exchange_ip_limit

  @doc false
  @spec credential_fingerprint(String.t()) :: String.t()
  def credential_fingerprint(delivery_token) when is_binary(delivery_token) do
    :crypto.hash(:sha256, @credential_prefix <> delivery_token)
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec token_redis_key(String.t()) :: String.t()
  def token_redis_key(delivery_token) do
    Namespace.key(
      "rate-limit:secure-ticket:exchange-token:#{credential_fingerprint(delivery_token)}"
    )
  end

  @doc false
  @spec ip_redis_key(String.t()) :: String.t()
  def ip_redis_key(client_ip) do
    Namespace.key("rate-limit:secure-ticket:exchange-ip:#{client_ip}")
  end

  defp token_key(delivery_token), do: token_redis_key(delivery_token)
  defp ip_key(client_ip), do: ip_redis_key(client_ip)

  defp check_bucket(redis_key, limit, redix_name) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    case redis_process(redix_name) do
      {:ok, _} ->
        eval_limit(redis_key, limit, nonce, redix_name)

      :error ->
        :unavailable
    end
  end

  defp eval_limit(redis_key, limit, nonce, redix_name) do
    args = [
      @lua_script,
      "1",
      redis_key,
      Integer.to_string(@window_seconds),
      Integer.to_string(limit),
      nonce,
      Integer.to_string(@key_ttl_seconds)
    ]

    case Redix.command(redix_name, ["EVAL" | args]) do
      {:ok, [1, _count, 0]} ->
        :allowed

      {:ok, [0, _count, retry_after]} when is_integer(retry_after) and retry_after > 0 ->
        {:rate_limited, retry_after}

      {:ok, [0, _count, retry_after]} ->
        {:rate_limited, max(retry_after, 1)}

      _ ->
        :unavailable
    end
  end

  defp redis_process(redix_name) do
    case Process.whereis(redix_name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end
end
