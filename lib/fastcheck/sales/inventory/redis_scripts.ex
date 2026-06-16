defmodule FastCheck.Sales.Inventory.RedisScripts do
  @moduledoc """
  Centralized Redis script boundary for Sales inventory ledger operations.

  This module is the only place that executes Lua for Sales inventory mutation.
  It never falls back to ETS; Redis unavailability fails closed.
  """

  @dedupe_ttl_seconds 86_400
  @order_lock_ttl_ms 5_000

  @reserve_script """
  local inventory_key = KEYS[1]
  local holds_key = KEYS[2]
  local hold_key = KEYS[3]
  local dedupe_key = KEYS[4]
  local lock_key = KEYS[5]

  local offer_id = ARGV[1]
  local order_ref = ARGV[2]
  local quantity = tonumber(ARGV[3])
  local ttl_seconds = tonumber(ARGV[4])
  local idempotency_key = ARGV[5]
  local now_ms = tonumber(ARGV[6])
  local args_sig = ARGV[7]
  local dedupe_ttl = tonumber(ARGV[8])
  local lock_ttl_ms = tonumber(ARGV[9])

  local existing_sig = redis.call("HGET", dedupe_key, "args_sig")
  if existing_sig then
    if existing_sig ~= args_sig then
      return {"DUPLICATE_CONFLICT"}
    end

    return {
      "IDEMPOTENT",
      redis.call("HGET", dedupe_key, "status"),
      redis.call("HGET", dedupe_key, "available_after"),
      redis.call("HGET", dedupe_key, "reserved_after"),
      redis.call("HGET", dedupe_key, "consumed_after"),
      redis.call("HGET", dedupe_key, "revision"),
      redis.call("HGET", dedupe_key, "expires_at")
    }
  end

  if redis.call("EXISTS", inventory_key) == 0 then
    return {"RECONCILIATION_REQUIRED"}
  end

  local ledger_state = redis.call("HGET", inventory_key, "ledger_state")
  if not ledger_state or ledger_state == "" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if ledger_state == "degraded" then
    return {"LEDGER_DEGRADED"}
  end

  if ledger_state == "reconciliation_required" or ledger_state == "closed" or ledger_state == "rebuilding" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if redis.call("SET", lock_key, "1", "NX", "PX", lock_ttl_ms) == false then
    return {"LOCK_TIMEOUT"}
  end

  if redis.call("EXISTS", hold_key) == 1 then
    local hold_status = redis.call("HGET", hold_key, "status")
    local hold_quantity = tonumber(redis.call("HGET", hold_key, "quantity") or "0")

    if hold_status == "held" then
      if hold_quantity ~= quantity then
        redis.call("DEL", lock_key)
        return {"QUANTITY_MISMATCH"}
      end

      local available = tonumber(redis.call("HGET", inventory_key, "available_quantity") or "0")
      local reserved = tonumber(redis.call("HGET", inventory_key, "reserved_quantity") or "0")
      local consumed = tonumber(redis.call("HGET", inventory_key, "consumed_quantity") or "0")
      local revision = tonumber(redis.call("HGET", inventory_key, "revision") or "0")
      local expires_at = redis.call("HGET", hold_key, "expires_at")

      redis.call(
        "HSET",
        dedupe_key,
        "args_sig", args_sig,
        "status", "held",
        "available_after", tostring(available),
        "reserved_after", tostring(reserved),
        "consumed_after", tostring(consumed),
        "revision", tostring(revision),
        "expires_at", expires_at
      )
      redis.call("EXPIRE", dedupe_key, dedupe_ttl)
      redis.call("DEL", lock_key)

      return {
        "IDEMPOTENT",
        "held",
        tostring(available),
        tostring(reserved),
        tostring(consumed),
        tostring(revision),
        expires_at
      }
    end

    if hold_status == "consumed" then
      redis.call("DEL", lock_key)
      return {"ALREADY_CONSUMED"}
    end

    if hold_status == "released" then
      redis.call("DEL", lock_key)
      return {"ALREADY_RELEASED"}
    end

    if hold_status == "expired" then
      redis.call("DEL", lock_key)
      return {"ALREADY_EXPIRED"}
    end

    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  local available = tonumber(redis.call("HGET", inventory_key, "available_quantity") or "-1")
  local reserved = tonumber(redis.call("HGET", inventory_key, "reserved_quantity") or "0")
  local consumed = tonumber(redis.call("HGET", inventory_key, "consumed_quantity") or "0")

  if available < 0 then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  if available < quantity then
    redis.call("DEL", lock_key)
    return {"INSUFFICIENT_INVENTORY"}
  end

  local revision = tonumber(redis.call("HGET", inventory_key, "revision") or "0") + 1
  local expires_at = now_ms + (ttl_seconds * 1000)
  local available_after = available - quantity
  local reserved_after = reserved + quantity

  redis.call(
    "HSET",
    inventory_key,
    "available_quantity", tostring(available_after),
    "reserved_quantity", tostring(reserved_after),
    "consumed_quantity", tostring(consumed),
    "revision", tostring(revision),
    "updated_at", tostring(now_ms)
  )

  redis.call(
    "HSET",
    hold_key,
    "offer_id", offer_id,
    "order_public_reference", order_ref,
    "quantity", tostring(quantity),
    "status", "held",
    "idempotency_key", idempotency_key,
    "created_at", tostring(now_ms),
    "expires_at", tostring(expires_at),
    "revision", tostring(revision)
  )

  redis.call("ZADD", holds_key, tostring(expires_at), order_ref)

  redis.call(
    "HSET",
    dedupe_key,
    "args_sig", args_sig,
    "status", "held",
    "available_after", tostring(available_after),
    "reserved_after", tostring(reserved_after),
    "consumed_after", tostring(consumed),
    "revision", tostring(revision),
    "expires_at", tostring(expires_at)
  )
  redis.call("EXPIRE", dedupe_key, dedupe_ttl)
  redis.call("DEL", lock_key)

  return {"OK", "held", tostring(available_after), tostring(reserved_after), tostring(consumed), tostring(revision), tostring(expires_at)}
  """

  @consume_script """
  local inventory_key = KEYS[1]
  local holds_key = KEYS[2]
  local hold_key = KEYS[3]
  local dedupe_key = KEYS[4]
  local lock_key = KEYS[5]

  local order_ref = ARGV[1]
  local quantity = tonumber(ARGV[2])
  local now_ms = tonumber(ARGV[3])
  local args_sig = ARGV[4]
  local dedupe_ttl = tonumber(ARGV[5])
  local lock_ttl_ms = tonumber(ARGV[6])

  local existing_sig = redis.call("HGET", dedupe_key, "args_sig")
  if existing_sig then
    if existing_sig ~= args_sig then
      return {"DUPLICATE_CONFLICT"}
    end

    return {
      "IDEMPOTENT",
      redis.call("HGET", dedupe_key, "status"),
      redis.call("HGET", dedupe_key, "available_after"),
      redis.call("HGET", dedupe_key, "reserved_after"),
      redis.call("HGET", dedupe_key, "consumed_after"),
      redis.call("HGET", dedupe_key, "revision")
    }
  end

  if redis.call("EXISTS", inventory_key) == 0 then
    return {"RECONCILIATION_REQUIRED"}
  end

  local ledger_state = redis.call("HGET", inventory_key, "ledger_state")
  if not ledger_state or ledger_state == "" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if ledger_state == "degraded" then
    return {"LEDGER_DEGRADED"}
  end

  if ledger_state == "reconciliation_required" or ledger_state == "closed" or ledger_state == "rebuilding" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if redis.call("SET", lock_key, "1", "NX", "PX", lock_ttl_ms) == false then
    return {"LOCK_TIMEOUT"}
  end

  if redis.call("EXISTS", hold_key) == 0 then
    redis.call("DEL", lock_key)
    return {"HOLD_NOT_FOUND"}
  end

  local hold_status = redis.call("HGET", hold_key, "status")
  local hold_quantity = tonumber(redis.call("HGET", hold_key, "quantity") or "0")

  if hold_status == "consumed" then
    redis.call("DEL", lock_key)
    return {"ALREADY_CONSUMED"}
  end

  if hold_status == "released" then
    redis.call("DEL", lock_key)
    return {"ALREADY_RELEASED"}
  end

  if hold_status == "expired" then
    redis.call("DEL", lock_key)
    return {"HOLD_EXPIRED"}
  end

  if hold_status ~= "held" then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  if hold_quantity ~= quantity then
    redis.call("DEL", lock_key)
    return {"QUANTITY_MISMATCH"}
  end

  local available = tonumber(redis.call("HGET", inventory_key, "available_quantity") or "0")
  local reserved = tonumber(redis.call("HGET", inventory_key, "reserved_quantity") or "0")
  local consumed = tonumber(redis.call("HGET", inventory_key, "consumed_quantity") or "0")
  local revision = tonumber(redis.call("HGET", inventory_key, "revision") or "0") + 1

  local reserved_after = reserved - quantity
  local consumed_after = consumed + quantity
  if reserved_after < 0 then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  redis.call(
    "HSET",
    inventory_key,
    "available_quantity", tostring(available),
    "reserved_quantity", tostring(reserved_after),
    "consumed_quantity", tostring(consumed_after),
    "revision", tostring(revision),
    "updated_at", tostring(now_ms)
  )

  redis.call(
    "HSET",
    hold_key,
    "status", "consumed",
    "consumed_at", tostring(now_ms),
    "revision", tostring(revision)
  )

  redis.call("ZREM", holds_key, order_ref)

  redis.call(
    "HSET",
    dedupe_key,
    "args_sig", args_sig,
    "status", "consumed",
    "available_after", tostring(available),
    "reserved_after", tostring(reserved_after),
    "consumed_after", tostring(consumed_after),
    "revision", tostring(revision)
  )
  redis.call("EXPIRE", dedupe_key, dedupe_ttl)
  redis.call("DEL", lock_key)

  return {"OK", "consumed", tostring(available), tostring(reserved_after), tostring(consumed_after), tostring(revision)}
  """

  @release_script """
  local inventory_key = KEYS[1]
  local holds_key = KEYS[2]
  local hold_key = KEYS[3]
  local dedupe_key = KEYS[4]
  local lock_key = KEYS[5]

  local order_ref = ARGV[1]
  local now_ms = tonumber(ARGV[2])
  local args_sig = ARGV[3]
  local dedupe_ttl = tonumber(ARGV[4])
  local lock_ttl_ms = tonumber(ARGV[5])

  local existing_sig = redis.call("HGET", dedupe_key, "args_sig")
  if existing_sig then
    if existing_sig ~= args_sig then
      return {"DUPLICATE_CONFLICT"}
    end

    return {
      "IDEMPOTENT",
      redis.call("HGET", dedupe_key, "status"),
      redis.call("HGET", dedupe_key, "available_after"),
      redis.call("HGET", dedupe_key, "reserved_after"),
      redis.call("HGET", dedupe_key, "consumed_after"),
      redis.call("HGET", dedupe_key, "revision")
    }
  end

  if redis.call("EXISTS", inventory_key) == 0 then
    return {"RECONCILIATION_REQUIRED"}
  end

  local ledger_state = redis.call("HGET", inventory_key, "ledger_state")
  if not ledger_state or ledger_state == "" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if ledger_state == "degraded" then
    return {"LEDGER_DEGRADED"}
  end

  if ledger_state == "reconciliation_required" or ledger_state == "closed" or ledger_state == "rebuilding" then
    return {"RECONCILIATION_REQUIRED"}
  end

  if redis.call("SET", lock_key, "1", "NX", "PX", lock_ttl_ms) == false then
    return {"LOCK_TIMEOUT"}
  end

  if redis.call("EXISTS", hold_key) == 0 then
    redis.call("DEL", lock_key)
    return {"HOLD_NOT_FOUND"}
  end

  local hold_status = redis.call("HGET", hold_key, "status")
  local hold_quantity = tonumber(redis.call("HGET", hold_key, "quantity") or "0")

  if hold_status == "consumed" then
    redis.call("DEL", lock_key)
    return {"ALREADY_CONSUMED"}
  end

  if hold_status == "released" then
    redis.call("DEL", lock_key)
    return {"ALREADY_RELEASED"}
  end

  if hold_status == "expired" then
    redis.call("DEL", lock_key)
    return {"ALREADY_EXPIRED"}
  end

  if hold_status ~= "held" then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  local available = tonumber(redis.call("HGET", inventory_key, "available_quantity") or "0")
  local reserved = tonumber(redis.call("HGET", inventory_key, "reserved_quantity") or "0")
  local consumed = tonumber(redis.call("HGET", inventory_key, "consumed_quantity") or "0")
  local revision = tonumber(redis.call("HGET", inventory_key, "revision") or "0") + 1

  local available_after = available + hold_quantity
  local reserved_after = reserved - hold_quantity
  if reserved_after < 0 then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  redis.call(
    "HSET",
    inventory_key,
    "available_quantity", tostring(available_after),
    "reserved_quantity", tostring(reserved_after),
    "consumed_quantity", tostring(consumed),
    "revision", tostring(revision),
    "updated_at", tostring(now_ms)
  )

  redis.call(
    "HSET",
    hold_key,
    "status", "released",
    "released_at", tostring(now_ms),
    "revision", tostring(revision)
  )

  redis.call("ZREM", holds_key, order_ref)

  redis.call(
    "HSET",
    dedupe_key,
    "args_sig", args_sig,
    "status", "released",
    "available_after", tostring(available_after),
    "reserved_after", tostring(reserved_after),
    "consumed_after", tostring(consumed),
    "revision", tostring(revision)
  )
  redis.call("EXPIRE", dedupe_key, dedupe_ttl)
  redis.call("DEL", lock_key)

  return {"OK", "released", tostring(available_after), tostring(reserved_after), tostring(consumed), tostring(revision)}
  """

  @expire_one_script """
  local inventory_key = KEYS[1]
  local holds_key = KEYS[2]
  local hold_key = KEYS[3]
  local lock_key = KEYS[4]

  local order_ref = ARGV[1]
  local now_ms = tonumber(ARGV[2])
  local lock_ttl_ms = tonumber(ARGV[3])

  if redis.call("EXISTS", inventory_key) == 0 then
    return {"RECONCILIATION_REQUIRED"}
  end

  if redis.call("SET", lock_key, "1", "NX", "PX", lock_ttl_ms) == false then
    return {"LOCK_TIMEOUT"}
  end

  if redis.call("EXISTS", hold_key) == 0 then
    redis.call("ZREM", holds_key, order_ref)
    redis.call("DEL", lock_key)
    return {"SKIP_MISSING"}
  end

  local hold_status = redis.call("HGET", hold_key, "status")
  if hold_status == "consumed" then
    redis.call("ZREM", holds_key, order_ref)
    redis.call("DEL", lock_key)
    return {"SKIP_CONSUMED"}
  end

  if hold_status == "released" then
    redis.call("ZREM", holds_key, order_ref)
    redis.call("DEL", lock_key)
    return {"SKIP_RELEASED"}
  end

  if hold_status == "expired" then
    redis.call("ZREM", holds_key, order_ref)
    redis.call("DEL", lock_key)
    return {"SKIP_EXPIRED"}
  end

  if hold_status ~= "held" then
    redis.call("ZREM", holds_key, order_ref)
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  local hold_quantity = tonumber(redis.call("HGET", hold_key, "quantity") or "0")
  local available = tonumber(redis.call("HGET", inventory_key, "available_quantity") or "0")
  local reserved = tonumber(redis.call("HGET", inventory_key, "reserved_quantity") or "0")
  local consumed = tonumber(redis.call("HGET", inventory_key, "consumed_quantity") or "0")
  local revision = tonumber(redis.call("HGET", inventory_key, "revision") or "0") + 1

  local available_after = available + hold_quantity
  local reserved_after = reserved - hold_quantity
  if reserved_after < 0 then
    redis.call("DEL", lock_key)
    return {"UNEXPECTED_RESPONSE"}
  end

  redis.call(
    "HSET",
    inventory_key,
    "available_quantity", tostring(available_after),
    "reserved_quantity", tostring(reserved_after),
    "consumed_quantity", tostring(consumed),
    "revision", tostring(revision),
    "updated_at", tostring(now_ms)
  )

  redis.call(
    "HSET",
    hold_key,
    "status", "expired",
    "expired_at", tostring(now_ms),
    "revision", tostring(revision)
  )

  redis.call("ZREM", holds_key, order_ref)
  redis.call("DEL", lock_key)
  return {"EXPIRED"}
  """

  @spec reserve(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def reserve(opts), do: eval_script(@reserve_script, opts)

  @spec consume(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def consume(opts), do: eval_script(@consume_script, opts)

  @spec release(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def release(opts), do: eval_script(@release_script, opts)

  @spec expire_one(keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def expire_one(opts), do: eval_script(@expire_one_script, opts)

  @spec execute(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, atom(), map()}
  def execute(command, args, opts \\ []) when is_binary(command) and is_list(args) do
    redix_name = Keyword.get(opts, :redix_name, FastCheck.Redix)
    offer_id = Keyword.get(opts, :offer_id)

    case Process.whereis(redix_name) do
      pid when is_pid(pid) ->
        case Redix.command(redix_name, [command | args]) do
          {:ok, response} ->
            decode_response(response, offer_id)

          {:error, reason} ->
            {:error, :ledger_unavailable, %{offer_id: offer_id, reason: inspect(reason)}}
        end

      _ ->
        {:error, :ledger_unavailable, %{offer_id: offer_id, reason: "redis_process_missing"}}
    end
  end

  defp eval_script(script, opts) do
    keys = Keyword.fetch!(opts, :keys)
    argv = Keyword.fetch!(opts, :argv)
    offer_id = Keyword.get(opts, :offer_id)

    execute("EVAL", [script, Integer.to_string(length(keys)) | keys ++ argv], offer_id: offer_id)
  end

  defp decode_response(["OK", status, available, reserved, consumed, revision | rest], _offer_id) do
    payload = %{
      status: parse_status(status),
      available_after: parse_int(available),
      reserved_after: parse_int(reserved),
      consumed_after: parse_int(consumed),
      revision: parse_int(revision),
      expires_at: parse_int(List.first(rest))
    }

    {:ok, payload}
  end

  defp decode_response(
         ["IDEMPOTENT", status, available, reserved, consumed, revision | rest],
         _offer_id
       ) do
    payload = %{
      status: parse_status(status),
      available_after: parse_int(available),
      reserved_after: parse_int(reserved),
      consumed_after: parse_int(consumed),
      revision: parse_int(revision),
      expires_at: parse_int(List.first(rest)),
      idempotent: true
    }

    {:ok, payload}
  end

  defp decode_response(["EXPIRED"], _offer_id), do: {:ok, %{expired: true}}
  defp decode_response(["SKIP_MISSING"], _offer_id), do: {:ok, %{skipped: :missing}}
  defp decode_response(["SKIP_CONSUMED"], _offer_id), do: {:ok, %{skipped: :consumed}}
  defp decode_response(["SKIP_RELEASED"], _offer_id), do: {:ok, %{skipped: :released}}
  defp decode_response(["SKIP_EXPIRED"], _offer_id), do: {:ok, %{skipped: :expired}}

  defp decode_response(["INSUFFICIENT_INVENTORY"], offer_id),
    do: {:error, :insufficient_inventory, %{offer_id: offer_id}}

  defp decode_response(["DUPLICATE_CONFLICT"], offer_id),
    do: {:error, :invalid_idempotency_key, %{offer_id: offer_id, reason: :duplicate_conflict}}

  defp decode_response(["HOLD_NOT_FOUND"], offer_id),
    do: {:error, :hold_not_found, %{offer_id: offer_id}}

  defp decode_response(["HOLD_EXPIRED"], offer_id),
    do: {:error, :hold_expired, %{offer_id: offer_id}}

  defp decode_response(["ALREADY_CONSUMED"], offer_id),
    do: {:error, :already_consumed, %{offer_id: offer_id}}

  defp decode_response(["ALREADY_RELEASED"], offer_id),
    do: {:error, :already_released, %{offer_id: offer_id}}

  defp decode_response(["ALREADY_EXPIRED"], offer_id),
    do: {:error, :hold_expired, %{offer_id: offer_id}}

  defp decode_response(["QUANTITY_MISMATCH"], offer_id),
    do: {:error, :invalid_quantity, %{offer_id: offer_id, reason: :quantity_mismatch}}

  defp decode_response(["LOCK_TIMEOUT"], offer_id),
    do: {:error, :lock_timeout, %{offer_id: offer_id}}

  defp decode_response(["LEDGER_DEGRADED"], offer_id),
    do: {:error, :ledger_degraded, %{offer_id: offer_id}}

  defp decode_response(["RECONCILIATION_REQUIRED"], offer_id),
    do: {:error, :reconciliation_required, %{offer_id: offer_id}}

  defp decode_response(["UNEXPECTED_RESPONSE"], offer_id),
    do: {:error, :unexpected_redis_response, %{offer_id: offer_id}}

  defp decode_response(other, offer_id),
    do: {:error, :unexpected_redis_response, %{offer_id: offer_id, response: inspect(other)}}

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil

  defp parse_status("held"), do: :held
  defp parse_status("consumed"), do: :consumed
  defp parse_status("released"), do: :released
  defp parse_status(other), do: other

  @spec dedupe_ttl_seconds() :: pos_integer()
  def dedupe_ttl_seconds, do: @dedupe_ttl_seconds

  @spec order_lock_ttl_ms() :: pos_integer()
  def order_lock_ttl_ms, do: @order_lock_ttl_ms
end
