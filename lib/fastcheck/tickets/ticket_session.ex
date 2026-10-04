defmodule FastCheck.Tickets.TicketSession do
  @moduledoc """
  P1-E browser ticket-session registry primitives (Redis HASH bindings).

  Owns opaque browser session identifiers, generation fingerprints, and atomic
  Redis bind/TTL/compare-and-delete operations. HTTP/cookie integration is P1E-C.
  """

  @session_idle_ttl_seconds 86_400
  @browser_session_random_bytes 32
  @binding_version "v1"
  @session_key_prefix "ticket-browser-session:v1:"
  @fingerprint_prefix "ticket-session:v1:"
  @fingerprint_encoded_length 43

  alias FastCheck.Redis.Namespace

  @bind_script """
  local session_key = KEYS[1]
  local field = ARGV[1]
  local incoming_gen = tonumber(ARGV[2])
  local incoming_fp = ARGV[3]
  local encoded = ARGV[4]
  local ttl = tonumber(ARGV[5])

  if not incoming_gen or incoming_gen < 0 or incoming_fp == '' or encoded == '' or not ttl then
    return {"INVALID"}
  end

  local function parse_binding(value)
    if not value then
      return nil
    end

    local version, gen_str, fingerprint = string.match(value, "^(v1):(%d+):([^:]+)$")

    if not version or not gen_str or not fingerprint then
      return nil
    end

    local generation = tonumber(gen_str)

    if not generation or generation < 0 then
      return nil
    end

    return generation, fingerprint
  end

  local current = redis.call("HGET", session_key, field)

  if current == false then
    redis.call("HSET", session_key, field, encoded)
    redis.call("EXPIRE", session_key, ttl)
    return {"BOUND"}
  end

  local current_gen, current_fp = parse_binding(current)

  if not current_gen then
    return {"INVALID"}
  end

  if incoming_gen < current_gen then
    return {"STALE_GENERATION"}
  end

  if incoming_gen == current_gen and incoming_fp ~= current_fp then
    return {"GENERATION_CONFLICT"}
  end

  if incoming_gen > current_gen or (incoming_gen == current_gen and incoming_fp == current_fp) then
    if incoming_gen > current_gen then
      redis.call("HSET", session_key, field, encoded)
    end

    redis.call("EXPIRE", session_key, ttl)
    return {"BOUND"}
  end

  return {"INVALID"}
  """

  @conditional_remove_script """
  local session_key = KEYS[1]
  local field = ARGV[1]
  local expected = ARGV[2]

  local current = redis.call("HGET", session_key, field)

  if current == expected then
    redis.call("HDEL", session_key, field)
    return {"REMOVED"}
  end

  return {"NOT_REMOVED"}
  """

  @refresh_ttl_script """
  local session_key = KEYS[1]
  local ttl = tonumber(ARGV[1])

  if not ttl then
    return {"INVALID"}
  end

  if redis.call("EXISTS", session_key) == 1 then
    redis.call("EXPIRE", session_key, ttl)
    return {"REFRESHED"}
  end

  return {"MISSING"}
  """

  @doc """
  Returns the production idle TTL (seconds) for ticket browser session registries.
  """
  @spec session_idle_ttl_seconds() :: pos_integer()
  def session_idle_ttl_seconds, do: @session_idle_ttl_seconds

  @doc """
  Creates a new opaque browser session identifier (32 random bytes, URL-safe Base64).
  """
  @spec new_browser_session_id() :: String.t()
  def new_browser_session_id do
    Base.url_encode64(:crypto.strong_rand_bytes(@browser_session_random_bytes), padding: false)
  end

  @doc """
  Derives the frozen generation fingerprint v1 from a delivery token hash.
  """
  @spec generation_fingerprint(String.t()) :: String.t()
  def generation_fingerprint(delivery_token_hash) when is_binary(delivery_token_hash) do
    digest = :crypto.hash(:sha256, @fingerprint_prefix <> delivery_token_hash)
    Base.url_encode64(digest, padding: false)
  end

  @doc """
  Returns the namespaced Redis key for a browser session registry HASH.
  """
  @spec registry_key(String.t()) :: String.t()
  def registry_key(browser_session_id) when is_binary(browser_session_id) do
    digest = :crypto.hash(:sha256, @session_key_prefix <> browser_session_id)
    session_id_hash = Base.url_encode64(digest, padding: false)
    Namespace.key("ticket-browser-session:" <> session_id_hash)
  end

  @doc """
  Atomically binds a ticket generation fingerprint to a browser session registry entry.
  """
  @spec bind(
          String.t(),
          pos_integer(),
          non_neg_integer(),
          String.t(),
          pos_integer(),
          keyword()
        ) ::
          {:ok, :bound}
          | {:error,
             :stale_generation | :generation_conflict | :invalid_binding | :registry_unavailable}
  def bind(
        browser_session_id,
        ticket_issue_id,
        incoming_generation,
        incoming_fingerprint,
        ttl_seconds,
        opts \\ []
      )
      when is_binary(browser_session_id) and is_integer(incoming_generation) and
             incoming_generation >= 0 and is_binary(incoming_fingerprint) and
             is_integer(ttl_seconds) and ttl_seconds > 0 do
    with {:ok, field} <- ticket_field(ticket_issue_id),
         {:ok, encoded} <- encode_binding(incoming_generation, incoming_fingerprint) do
      eval_script(
        @bind_script,
        [registry_key(browser_session_id)],
        [
          field,
          Integer.to_string(incoming_generation),
          incoming_fingerprint,
          encoded,
          Integer.to_string(ttl_seconds)
        ],
        opts
      )
    end
  end

  @doc """
  Reads one ticket binding from the browser session registry without refreshing TTL.
  """
  @spec fetch_binding(String.t(), pos_integer(), keyword()) ::
          {:ok, %{generation: non_neg_integer(), fingerprint: String.t(), encoded: String.t()}}
          | {:error, :not_found | :invalid_binding | :registry_unavailable}
  def fetch_binding(browser_session_id, ticket_issue_id, opts \\ [])
      when is_binary(browser_session_id) do
    with {:ok, field} <- ticket_field(ticket_issue_id),
         {:ok, raw} <- hget(registry_key(browser_session_id), field, opts) do
      case raw do
        nil ->
          {:error, :not_found}

        value ->
          case decode_binding(value) do
            {:ok, binding} -> {:ok, binding}
            :error -> {:error, :invalid_binding}
          end
      end
    end
  end

  @doc """
  Atomically removes a ticket binding only when the stored value matches exactly.
  """
  @spec conditional_remove(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, :removed | :not_removed}
          | {:error, :invalid_binding | :registry_unavailable}
  def conditional_remove(browser_session_id, ticket_issue_id, expected_encoded, opts \\ [])
      when is_binary(browser_session_id) and is_binary(expected_encoded) do
    with {:ok, field} <- ticket_field(ticket_issue_id),
         :ok <- validate_encoded_binding(expected_encoded),
         {:ok, status} <-
           eval_script(
             @conditional_remove_script,
             [registry_key(browser_session_id)],
             [field, expected_encoded],
             opts
           ) do
      case status do
        :removed -> {:ok, :removed}
        :not_removed -> {:ok, :not_removed}
        :invalid -> {:error, :invalid_binding}
        :registry_unavailable -> {:error, :registry_unavailable}
      end
    else
      {:error, :invalid_binding} = error -> error
      {:error, :registry_unavailable} = error -> error
      :error -> {:error, :invalid_binding}
    end
  end

  @doc """
  Refreshes idle TTL on an existing browser session registry key without creating it.
  """
  @spec refresh_ttl_if_exists(String.t(), pos_integer(), keyword()) ::
          {:ok, :refreshed | :missing} | {:error, :registry_unavailable}
  def refresh_ttl_if_exists(browser_session_id, ttl_seconds, opts \\ [])
      when is_binary(browser_session_id) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    case eval_script(
           @refresh_ttl_script,
           [registry_key(browser_session_id)],
           [Integer.to_string(ttl_seconds)],
           opts
         ) do
      {:ok, :refreshed} -> {:ok, :refreshed}
      {:ok, :missing} -> {:ok, :missing}
      {:error, :registry_unavailable} -> {:error, :registry_unavailable}
      {:error, _} -> {:error, :registry_unavailable}
    end
  end

  @doc false
  @spec encode_binding(non_neg_integer(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_binding}
  def encode_binding(generation, fingerprint)
      when is_integer(generation) and generation >= 0 and is_binary(fingerprint) do
    if valid_fingerprint?(fingerprint) do
      {:ok, "#{@binding_version}:#{generation}:#{fingerprint}"}
    else
      {:error, :invalid_binding}
    end
  end

  @doc false
  @spec decode_binding(String.t()) ::
          {:ok, %{generation: non_neg_integer(), fingerprint: String.t(), encoded: String.t()}}
          | :error
  def decode_binding(encoded) when is_binary(encoded) do
    parts = String.split(encoded, ":", parts: 3)

    case parts do
      [@binding_version, generation_str, fingerprint] ->
        with {generation, ""} <- Integer.parse(generation_str),
             true <- generation >= 0,
             true <- valid_fingerprint?(fingerprint) do
          {:ok, %{generation: generation, fingerprint: fingerprint, encoded: encoded}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp ticket_field(ticket_issue_id) when is_integer(ticket_issue_id) and ticket_issue_id > 0 do
    {:ok, "ticket:#{ticket_issue_id}"}
  end

  defp ticket_field(_), do: {:error, :invalid_binding}

  defp validate_encoded_binding(encoded) do
    case decode_binding(encoded) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_binding}
    end
  end

  defp valid_fingerprint?(fingerprint) do
    byte_size(fingerprint) == @fingerprint_encoded_length and
      Regex.match?(~r/^[A-Za-z0-9_-]+$/, fingerprint)
  end

  defp hget(key, field, opts) do
    redix_name = Keyword.get(opts, :redix_name, FastCheck.Redix)

    case redis_process(redix_name) do
      {:ok, _} ->
        case Redix.command(redix_name, ["HGET", key, field]) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, normalize_redis_error(reason)}
        end

      {:error, :registry_unavailable} = error ->
        error
    end
  end

  defp eval_script(script, keys, argv, opts) do
    redix_name = Keyword.get(opts, :redix_name, FastCheck.Redix)
    args = [script, Integer.to_string(length(keys)) | keys ++ argv]

    case redis_process(redix_name) do
      {:ok, _} ->
        case Redix.command(redix_name, ["EVAL" | args]) do
          {:ok, [status]} -> decode_script_status(status)
          {:ok, _} -> {:error, :registry_unavailable}
          {:error, reason} -> {:error, normalize_redis_error(reason)}
        end

      {:error, :registry_unavailable} = error ->
        error
    end
  end

  defp decode_script_status("BOUND"), do: {:ok, :bound}
  defp decode_script_status("STALE_GENERATION"), do: {:error, :stale_generation}
  defp decode_script_status("GENERATION_CONFLICT"), do: {:error, :generation_conflict}
  defp decode_script_status("INVALID"), do: {:error, :invalid_binding}
  defp decode_script_status("REMOVED"), do: {:ok, :removed}
  defp decode_script_status("NOT_REMOVED"), do: {:ok, :not_removed}
  defp decode_script_status("REFRESHED"), do: {:ok, :refreshed}
  defp decode_script_status("MISSING"), do: {:ok, :missing}
  defp decode_script_status(_), do: {:error, :registry_unavailable}

  defp redis_process(redix_name) do
    case Process.whereis(redix_name) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :registry_unavailable}
    end
  end

  defp normalize_redis_error(_reason), do: :registry_unavailable
end
