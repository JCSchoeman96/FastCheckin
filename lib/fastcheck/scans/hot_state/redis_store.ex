defmodule FastCheck.Scans.HotState.RedisStore do
  @moduledoc """
  Redis-backed hot state store for mobile scan ingestion.
  """

  import Ecto.Query, only: [from: 2]

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Scans.HotState.Keyspace
  alias FastCheck.Scans.Ingest.ScanCommand
  alias FastCheck.Scans.Result

  @build_lock_ttl 30
  @idempotency_ttl_seconds 7 * 24 * 60 * 60
  @build_wait_attempts 20
  @build_wait_ms 100

  @decision_script """
  local idem_key = KEYS[1]
  local ticket_key = KEYS[2]

  local processed_at = ARGV[1]
  local scanned_at = ARGV[2]
  local direction = ARGV[3]
  local idempotency_key = ARGV[4]
  local ticket_code = ARGV[5]
  local entrance_name = ARGV[6]
  local operator_name = ARGV[7]
  local hot_state_version = ARGV[8]
  local ttl_seconds = tonumber(ARGV[9])
  local allow_unknown_payment = ARGV[10]

  local existing_delivery_state = redis.call("HGET", idem_key, "delivery_state")

  if existing_delivery_state then
    return {
      existing_delivery_state == "final_acknowledged" and "replay_final" or "replay_pending",
      redis.call("HGET", idem_key, "status") or "error",
      redis.call("HGET", idem_key, "reason_code") or "ERROR",
      redis.call("HGET", idem_key, "message") or "Unable to process scan",
      redis.call("HGET", idem_key, "attendee_id") or "",
      redis.call("HGET", idem_key, "processed_at") or processed_at,
      redis.call("HGET", idem_key, "scanned_at") or scanned_at,
      redis.call("HGET", idem_key, "direction") or direction,
      redis.call("HGET", idem_key, "entrance_name") or entrance_name,
      redis.call("HGET", idem_key, "operator_name") or operator_name,
      redis.call("HGET", idem_key, "hot_state_version") or hot_state_version,
      redis.call("HGET", idem_key, "remaining_after") or "",
      redis.call("HGET", idem_key, "checked_in_at_value") or ""
    }
  end

  local ticket = redis.call(
    "HMGET",
    ticket_key,
    "attendee_id",
    "payment_status",
    "allowed_checkins",
    "checkins_remaining",
    "checked_in_at"
  )

  local attendee_id = ticket[1]
  local payment_status = ticket[2]
  local allowed_checkins = tonumber(ticket[3] or "1")
  local checkins_remaining = tonumber(ticket[4] or ticket[3] or "1")
  local checked_in_at = ticket[5] or ""

  local status = "error"
  local reason_code = "ERROR"
  local message = "Unable to process scan"
  local remaining_after = tostring(checkins_remaining)
  local checked_in_at_value = checked_in_at

  if not attendee_id or attendee_id == false then
    reason_code = "INVALID"
    message = "Ticket not found: Ticket not found"
  elseif direction ~= "in" then
    reason_code = "NOT_IMPLEMENTED"
    message = "Check-out functionality not yet available"
  else
    local normalized_payment = "unknown"

    if payment_status and payment_status ~= false then
      normalized_payment = string.lower(payment_status)
      if string.sub(normalized_payment, 1, 3) == "wc-" then
        normalized_payment = string.sub(normalized_payment, 4)
      end

      if normalized_payment == "" then
        normalized_payment = "unknown"
      elseif string.find(normalized_payment, "completed") then
        normalized_payment = "completed"
      end
    end

    local payment_valid = normalized_payment == "completed" or
      (normalized_payment == "unknown" and allow_unknown_payment == "1")

    if not payment_valid then
      reason_code = "PAYMENT_INVALID"
      message = "Payment invalid: Entry denied: order status '" .. normalized_payment .. "' is not completed"
    elseif checked_in_at ~= "" and checkins_remaining <= 0 then
      reason_code = "DUPLICATE"
      message = "Already checked in: Already checked in at " .. checked_in_at
    else
      status = "success"
      reason_code = "SUCCESS"
      message = "Check-in successful"
      remaining_after = tostring(math.max(checkins_remaining - 1, 0))
      checked_in_at_value = processed_at

      redis.call(
        "HSET",
        ticket_key,
        "checkins_remaining",
        remaining_after,
        "checked_in_at",
        checked_in_at_value
      )
    end
  end

  redis.call(
    "HSET",
    idem_key,
    "delivery_state",
    "pending_durability",
    "status",
    status,
    "reason_code",
    reason_code,
    "message",
    message,
    "attendee_id",
    attendee_id or "",
    "ticket_code",
    ticket_code,
    "direction",
    direction,
    "entrance_name",
    entrance_name,
    "operator_name",
    operator_name,
    "processed_at",
    processed_at,
    "scanned_at",
    scanned_at,
    "hot_state_version",
    hot_state_version,
    "remaining_after",
    remaining_after,
    "checked_in_at_value",
    checked_in_at_value
  )

  redis.call("EXPIRE", idem_key, ttl_seconds)

  return {
    "new_pending",
    status,
    reason_code,
    message,
    attendee_id or "",
    processed_at,
    scanned_at,
    direction,
    entrance_name,
    operator_name,
    hot_state_version,
    remaining_after,
    checked_in_at_value
  }
  """

  @spec ensure_event_loaded(integer(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_event_loaded(event_id, namespace) when is_integer(event_id) do
    with {:ok, version} <- fetch_active_version(namespace, event_id) do
      case version do
        nil -> build_event_snapshot(namespace, event_id)
        _ -> {:ok, version}
      end
    end
  end

  @spec process_scan(ScanCommand.t(), String.t()) :: {:ok, Result.t()} | {:error, term()}
  def process_scan(%ScanCommand{} = command, namespace) do
    with {:ok, version} <- ensure_event_loaded(command.event_id, namespace),
         {:ok, response} <- eval_decision(command, namespace, version) do
      {:ok, to_result(command.event_id, command.idempotency_key, command.ticket_code, response)}
    end
  end

  @spec promote_results([Result.t()], String.t()) :: :ok | {:error, term()}
  def promote_results(results, namespace) when is_list(results) do
    results
    |> Enum.map(&promotion_command(&1, namespace))
    |> case do
      [] ->
        :ok

      commands ->
        case redis_pipeline(commands) do
          {:ok, _responses} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def promote_results(_results, _namespace), do: {:error, :invalid_results}

  defp fetch_active_version(namespace, event_id) do
    case redis_command(["GET", Keyspace.active_version(namespace, event_id)]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, version} when is_binary(version) and version != "" -> {:ok, version}
      {:ok, _other} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_event_snapshot(namespace, event_id) do
    lock_key = Keyspace.build_lock(namespace, event_id)

    case redis_command(["SET", lock_key, "1", "NX", "EX", Integer.to_string(@build_lock_ttl)]) do
      {:ok, "OK"} ->
        do_build_event_snapshot(namespace, event_id, lock_key)

      {:ok, nil} ->
        await_active_version(namespace, event_id, @build_wait_attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_build_event_snapshot(namespace, event_id, lock_key) do
    try do
      version = Integer.to_string(System.system_time(:millisecond))

      attendees =
        Repo.all(
          from attendee in Attendee,
            where: attendee.event_id == ^event_id,
            select: %{
              attendee_id: attendee.id,
              ticket_code: attendee.ticket_code,
              payment_status: attendee.payment_status,
              allowed_checkins: attendee.allowed_checkins,
              checkins_remaining: attendee.checkins_remaining,
              checked_in_at: attendee.checked_in_at
            }
        )

      ticket_commands =
        Enum.map(attendees, fn attendee ->
          [
            "HSET",
            Keyspace.ticket(namespace, event_id, version, attendee.ticket_code),
            "attendee_id",
            to_string(attendee.attendee_id),
            "payment_status",
            normalize_binary(attendee.payment_status, "unknown"),
            "allowed_checkins",
            to_string(attendee.allowed_checkins || 1),
            "checkins_remaining",
            to_string(attendee.checkins_remaining || attendee.allowed_checkins || 1),
            "checked_in_at",
            datetime_to_string(attendee.checked_in_at)
          ]
        end)

      with {:ok, _} <- maybe_pipeline(ticket_commands),
           {:ok, "OK"} <-
             redis_command(["SET", Keyspace.active_version(namespace, event_id), version]) do
        {:ok, version}
      end
    after
      _ = redis_command(["DEL", lock_key])
    end
  end

  defp await_active_version(namespace, event_id, attempts_left) when attempts_left > 0 do
    Process.sleep(@build_wait_ms)

    case fetch_active_version(namespace, event_id) do
      {:ok, nil} -> await_active_version(namespace, event_id, attempts_left - 1)
      {:ok, version} -> {:ok, version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_active_version(_namespace, _event_id, _attempts_left), do: {:error, :build_timeout}

  defp eval_decision(%ScanCommand{} = command, namespace, version) do
    processed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    keys = [
      Keyspace.idempotency(namespace, command.event_id, command.idempotency_key),
      Keyspace.ticket(namespace, command.event_id, version, command.ticket_code)
    ]

    args = [
      DateTime.to_iso8601(processed_at),
      datetime_to_string(command.scanned_at || processed_at),
      command.direction,
      command.idempotency_key,
      command.ticket_code,
      normalize_binary(command.entrance_name, "Mobile"),
      normalize_binary(command.operator_name, "Mobile Scanner"),
      version,
      Integer.to_string(@idempotency_ttl_seconds),
      if(Application.get_env(:fastcheck, :allow_unknown_payment_status, false),
        do: "1",
        else: "0"
      )
    ]

    redis_command(["EVAL", @decision_script, Integer.to_string(length(keys)) | keys ++ args])
  end

  defp to_result(event_id, idempotency_key, ticket_code, [
         replay_code,
         status,
         reason_code,
         message,
         attendee_id,
         processed_at,
         scanned_at,
         direction,
         entrance_name,
         operator_name,
         hot_state_version,
         remaining_after,
         checked_in_at_value
       ]) do
    delivery_state =
      case replay_code do
        "new_pending" -> :new_staged
        "replay_pending" -> :pending_durability
        "replay_final" -> :final_acknowledged
      end

    %Result{
      event_id: event_id,
      attendee_id: parse_integer(attendee_id),
      idempotency_key: idempotency_key,
      ticket_code: ticket_code,
      direction: direction,
      status: status,
      reason_code: reason_code,
      message: message,
      entrance_name: blank_to_nil(entrance_name),
      operator_name: blank_to_nil(operator_name),
      scanned_at: parse_datetime(scanned_at),
      processed_at:
        parse_datetime(processed_at) || DateTime.utc_now() |> DateTime.truncate(:second),
      delivery_state: delivery_state,
      hot_state_version: hot_state_version,
      metadata: %{
        "remaining_after" => parse_integer(remaining_after),
        "checked_in_at" => blank_to_nil(checked_in_at_value)
      }
    }
  end

  defp promotion_command(%Result{} = result, namespace) do
    [
      "HSET",
      Keyspace.idempotency(namespace, result.event_id, result.idempotency_key),
      "delivery_state",
      "final_acknowledged"
    ]
  end

  defp maybe_pipeline([]), do: {:ok, []}
  defp maybe_pipeline(commands), do: redis_pipeline(commands)

  defp redis_pipeline(commands) do
    case Process.whereis(FastCheck.Redix) do
      pid when is_pid(pid) -> Redix.pipeline(FastCheck.Redix, commands)
      _ -> {:error, :redis_unavailable}
    end
  end

  defp redis_command(command) do
    case Process.whereis(FastCheck.Redix) do
      pid when is_pid(pid) -> Redix.command(FastCheck.Redix, command)
      _ -> {:error, :redis_unavailable}
    end
  end

  defp datetime_to_string(nil), do: ""
  defp datetime_to_string(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_to_string(value) when is_binary(value), do: value

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp normalize_binary(nil, default), do: default

  defp normalize_binary(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
