defmodule FastCheckWeb.Mobile.SyncController do
  @moduledoc """
  Handles mobile client data synchronization operations.

  Mobile scanners use this controller to:
  - Download attendee data for offline mode (sync down)
  - Upload queued scans when connectivity returns (sync up)
  """

  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  require Logger

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo

  @default_mobile_sync_parallel true
  @default_mobile_sync_max_concurrency 16
  @default_mobile_sync_task_timeout_ms 10_000

  @idempotency_pending_result "__pending__"
  @idempotency_poll_attempts 10
  @idempotency_poll_interval_ms 25
  @idempotency_pending_stale_multiplier 2
  @idempotency_pending_stale_floor_ms 15_000

  @doc """
  Returns attendee data for the authenticated event (sync down).
  """
  def get_attendees(conn, params) do
    event_id = conn.assigns.current_event_id

    with {:ok, since_timestamp} <- parse_since_parameter(params),
         {:ok, attendees} <- fetch_attendees(event_id, since_timestamp) do
      server_time = DateTime.utc_now() |> DateTime.truncate(:second)
      sync_type = if since_timestamp, do: "incremental", else: "full"

      Logger.info("Mobile sync down completed",
        event_id: event_id,
        sync_type: sync_type,
        count: length(attendees),
        since: since_timestamp,
        ip: get_peer_ip(conn)
      )

      json(conn, %{
        data: %{
          server_time: DateTime.to_iso8601(server_time),
          attendees: Enum.map(attendees, &serialize_attendee/1),
          count: length(attendees),
          sync_type: sync_type
        },
        error: nil
      })
    else
      {:error, reason} ->
        Logger.error("Mobile sync down failed",
          event_id: event_id,
          reason: inspect(reason),
          ip: get_peer_ip(conn)
        )

        server_error(conn, "sync_failed", "Unable to retrieve attendee data")
    end
  end

  @doc """
  Accepts a batch of scanned check-ins from mobile clients (sync up).
  """
  def upload_scans(conn, %{"scans" => scans}) when is_list(scans) do
    event_id = conn.assigns.current_event_id
    started_at = System.monotonic_time(:millisecond)
    sync_config = mobile_sync_config()

    Logger.info("Mobile scan upload started",
      event_id: event_id,
      scan_count: length(scans),
      ip: get_peer_ip(conn),
      parallel: sync_config.parallel,
      max_concurrency: sync_config.max_concurrency
    )

    results = process_scans_batch(event_id, scans, sync_config)

    success_count = Enum.count(results, &(&1.status == "success"))
    duplicate_count = Enum.count(results, &(&1.status == "duplicate"))
    error_count = Enum.count(results, &(&1.status == "error"))
    duration_ms = System.monotonic_time(:millisecond) - started_at

    emit_mobile_sync_batch_telemetry(
      event_id,
      length(results),
      success_count,
      duplicate_count,
      error_count,
      duration_ms
    )

    Logger.info("Mobile scan upload completed",
      event_id: event_id,
      total: length(results),
      success: success_count,
      duplicate: duplicate_count,
      error: error_count,
      duration_ms: duration_ms,
      ip: get_peer_ip(conn)
    )

    json(conn, %{
      data: %{
        results: results,
        processed: length(results)
      },
      error: nil
    })
  end

  def upload_scans(conn, _params) do
    bad_request(conn, "invalid_request", "Request body must contain 'scans' array")
  end

  # ========================================================================
  # Scan Processing Helpers
  # ========================================================================

  defp process_scans_batch(event_id, scans, %{parallel: true} = sync_config)
       when is_integer(event_id) and is_list(scans) and length(scans) > 1 do
    indexed_scans = Enum.with_index(scans)

    indexed_scans
    |> Enum.zip(
      Task.async_stream(
        indexed_scans,
        fn {scan, index} -> {index, process_scan(event_id, scan, sync_config)} end,
        max_concurrency: sync_config.max_concurrency,
        timeout: sync_config.task_timeout_ms,
        on_timeout: :kill_task,
        ordered: true
      )
    )
    |> Enum.map(fn {{scan, index}, task_result} ->
      case task_result do
        {:ok, {_result_index, result}} ->
          {index, result}

        {:exit, reason} ->
          _ = release_pending_reservation(event_id, scan)
          {index, task_exit_result(scan, reason)}
      end
    end)
    |> Enum.sort_by(fn {index, _result} -> index end)
    |> Enum.map(fn {_index, result} -> result end)
  end

  defp process_scans_batch(event_id, scans, sync_config)
       when is_integer(event_id) and is_list(scans) do
    scans
    |> Enum.with_index()
    |> Enum.map(fn {scan, index} -> {index, process_scan(event_id, scan, sync_config)} end)
    |> Enum.sort_by(fn {index, _result} -> index end)
    |> Enum.map(fn {_index, result} -> result end)
  end

  defp process_scans_batch(_event_id, scans, _sync_config) when is_list(scans) do
    Enum.map(scans, fn scan ->
      %{
        idempotency_key: Map.get(scan, "idempotency_key", "unknown"),
        status: "error",
        message: "Invalid event context"
      }
    end)
  end

  defp process_scan(event_id, scan, sync_config) do
    started_at = System.monotonic_time(:millisecond)

    result =
      with {:ok, validated_scan} <- validate_scan(scan),
           {:ok, reservation_status} <- reserve_idempotency(event_id, validated_scan),
           {:ok, processed_result} <-
             process_reserved_scan(event_id, validated_scan, reservation_status, sync_config) do
        processed_result
      else
        {:error, reason} ->
          %{
            idempotency_key: Map.get(scan, "idempotency_key", "unknown"),
            status: "error",
            message: reason
          }
      end

    duration_ms = System.monotonic_time(:millisecond) - started_at
    emit_mobile_sync_scan_telemetry(event_id, result.status, duration_ms)
    result
  end

  defp validate_scan(scan) when is_map(scan) do
    with {:ok, key} <- extract_field(scan, "idempotency_key"),
         {:ok, ticket_code} <- extract_field(scan, "ticket_code"),
         {:ok, direction} <- extract_field(scan, "direction"),
         :ok <- validate_direction(direction) do
      {:ok,
       %{
         idempotency_key: key,
         ticket_code: ticket_code,
         direction: direction,
         entrance_name: scan["entrance_name"] || "Mobile",
         operator_name: scan["operator_name"] || "Mobile Scanner",
         scanned_at: scan["scanned_at"]
       }}
    end
  end

  defp validate_scan(_), do: {:error, "Invalid scan format"}

  defp extract_field(scan, field) do
    case Map.get(scan, field) do
      value when is_binary(value) ->
        trimmed = String.trim(value)

        if trimmed == "" do
          {:error, "Empty value for required field: #{field}"}
        else
          {:ok, trimmed}
        end

      nil ->
        {:error, "Missing required field: #{field}"}

      _ ->
        {:error, "Invalid value for required field: #{field}"}
    end
  end

  defp validate_direction("in"), do: :ok
  defp validate_direction("out"), do: :ok

  defp validate_direction(invalid),
    do: {:error, "Invalid direction: #{invalid}. Must be 'in' or 'out'"}

  defp mobile_sync_config do
    config = Application.get_env(:fastcheck, :mobile_sync_performance, [])

    %{
      parallel: normalize_boolean(Keyword.get(config, :parallel, @default_mobile_sync_parallel)),
      max_concurrency:
        normalize_integer(
          Keyword.get(config, :max_concurrency, @default_mobile_sync_max_concurrency),
          @default_mobile_sync_max_concurrency
        ),
      task_timeout_ms:
        normalize_integer(
          Keyword.get(config, :task_timeout_ms, @default_mobile_sync_task_timeout_ms),
          @default_mobile_sync_task_timeout_ms
        )
    }
  end

  defp normalize_boolean(value) when value in [true, false], do: value

  defp normalize_boolean(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      normalized when normalized in ["1", "true", "yes", "on"] -> true
      _ -> false
    end
  end

  defp normalize_boolean(_value), do: false

  defp normalize_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp reserve_idempotency(event_id, scan) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    values = [
      %{
        event_id: event_id,
        idempotency_key: scan.idempotency_key,
        ticket_code: scan.ticket_code,
        result: @idempotency_pending_result,
        metadata: %{
          "status" => "pending",
          "direction" => scan.direction,
          "scanned_at" => scan.scanned_at,
          "reserved_at" => DateTime.to_iso8601(now)
        },
        inserted_at: now,
        updated_at: now
      }
    ]

    case Repo.insert_all(MobileIdempotencyLog, values,
           on_conflict: :nothing,
           conflict_target: [:event_id, :idempotency_key]
         ) do
      {1, _rows} -> {:ok, :reserved}
      {0, _rows} -> {:ok, :duplicate}
      _ -> {:error, "Unable to reserve scan idempotency record"}
    end
  rescue
    exception ->
      Logger.warning(
        "Idempotency reservation failed for event #{event_id} key #{scan.idempotency_key}: #{Exception.message(exception)}"
      )

      {:error, "Unable to reserve scan idempotency record"}
  end

  defp process_reserved_scan(event_id, scan, :reserved, _sync_config) do
    with {:ok, api_result} <- execute_scan(event_id, scan),
         :ok <- persist_idempotency_result(event_id, scan, api_result) do
      {:ok, api_result}
    end
  end

  defp process_reserved_scan(event_id, scan, :duplicate, sync_config) do
    case await_idempotency_result(event_id, scan.idempotency_key, @idempotency_poll_attempts) do
      {:ok, %{result: @idempotency_pending_result} = row} ->
        handle_pending_duplicate(event_id, scan, row, sync_config)

      {:ok, %{result: result, metadata: metadata}} ->
        {:ok,
         %{
           idempotency_key: scan.idempotency_key,
           status: "duplicate",
           message: duplicate_message(result, metadata)
         }}

      :not_found ->
        {:ok,
         %{
           idempotency_key: scan.idempotency_key,
           status: "duplicate",
           message: "Already processed"
         }}
    end
  end

  defp process_reserved_scan(_event_id, _scan, _reservation_status, _sync_config),
    do: {:error, "Invalid reservation status"}

  defp await_idempotency_result(event_id, idempotency_key, attempts_left)
       when attempts_left > 0 do
    case fetch_idempotency_result(event_id, idempotency_key) do
      {:ok, %{result: @idempotency_pending_result}} ->
        Process.sleep(@idempotency_poll_interval_ms)
        await_idempotency_result(event_id, idempotency_key, attempts_left - 1)

      {:ok, row} ->
        {:ok, row}

      :not_found ->
        :not_found
    end
  end

  defp await_idempotency_result(event_id, idempotency_key, _attempts_left) do
    case fetch_idempotency_result(event_id, idempotency_key) do
      {:ok, row} -> {:ok, row}
      :not_found -> :not_found
    end
  end

  defp fetch_idempotency_result(event_id, idempotency_key) do
    query =
      from log in MobileIdempotencyLog,
        where: log.event_id == ^event_id and log.idempotency_key == ^idempotency_key,
        select: %{result: log.result, metadata: log.metadata, updated_at: log.updated_at}

    case Repo.one(query) do
      nil -> :not_found
      row -> {:ok, row}
    end
  end

  defp duplicate_message(result, metadata) do
    stored_message = metadata_message(metadata)

    cond do
      is_binary(stored_message) and String.trim(stored_message) != "" ->
        "Already processed: #{stored_message}"

      is_binary(result) and String.trim(result) != "" and result != @idempotency_pending_result ->
        "Already processed: #{result}"

      true ->
        "Already processed"
    end
  end

  defp metadata_message(metadata) when is_map(metadata) do
    Map.get(metadata, "message") || Map.get(metadata, :message)
  end

  defp metadata_message(_metadata), do: nil

  defp handle_pending_duplicate(event_id, scan, row, sync_config) do
    if pending_stale?(row, sync_config.task_timeout_ms) do
      _ = release_pending_reservation(event_id, scan.idempotency_key)
      {:error, "Previous scan attempt timed out. Please retry."}
    else
      {:error, "Scan is still being processed. Retry shortly."}
    end
  end

  defp pending_stale?(%{updated_at: %DateTime{} = updated_at}, task_timeout_ms) do
    stale_after_ms =
      max(
        task_timeout_ms * @idempotency_pending_stale_multiplier,
        @idempotency_pending_stale_floor_ms
      )

    DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) >= stale_after_ms
  end

  defp pending_stale?(_row, _task_timeout_ms), do: true

  defp release_pending_reservation(event_id, scan) when is_integer(event_id) and is_map(scan) do
    case Map.get(scan, "idempotency_key") do
      key when is_binary(key) ->
        release_pending_reservation(event_id, key)

      _ ->
        :ok
    end
  end

  defp release_pending_reservation(event_id, idempotency_key)
       when is_integer(event_id) and is_binary(idempotency_key) do
    normalized = String.trim(idempotency_key)

    if normalized == "" do
      :ok
    else
      query =
        from log in MobileIdempotencyLog,
          where:
            log.event_id == ^event_id and
              log.idempotency_key == ^normalized and
              log.result == ^@idempotency_pending_result

      case Repo.delete_all(query) do
        {deleted, _} when deleted > 0 ->
          Logger.warning("Released stale mobile idempotency reservation",
            event_id: event_id,
            idempotency_key: normalized,
            removed: deleted
          )

          :ok

        _ ->
          :ok
      end
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to release mobile idempotency reservation for event #{event_id} key #{idempotency_key}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp release_pending_reservation(_event_id, _idempotency_key), do: :ok

  defp persist_idempotency_result(event_id, scan, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from log in MobileIdempotencyLog,
        where: log.event_id == ^event_id and log.idempotency_key == ^scan.idempotency_key

    Repo.update_all(query,
      set: [
        result: result.status,
        metadata: %{
          "status" => result.status,
          "message" => result.message,
          "direction" => scan.direction,
          "scanned_at" => scan.scanned_at,
          "processed_at" => DateTime.to_iso8601(now)
        },
        updated_at: now
      ]
    )

    :ok
  rescue
    exception ->
      Logger.warning(
        "Idempotency result persistence failed for event #{event_id} key #{scan.idempotency_key}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp execute_scan(event_id, scan) do
    domain_result =
      case scan.direction do
        "in" ->
          FastCheck.Attendees.check_in(
            event_id,
            scan.ticket_code,
            scan.entrance_name,
            scan.operator_name
          )

        "out" ->
          {:error, "NOT_IMPLEMENTED", "Check-out functionality not yet available"}
      end

    {:ok, map_domain_result(scan.idempotency_key, domain_result)}
  end

  defp map_domain_result(key, {:ok, _attendee, "SUCCESS"}) do
    %{
      idempotency_key: key,
      status: "success",
      message: "Check-in successful"
    }
  end

  defp map_domain_result(key, {:ok, _attendee, message}) do
    %{
      idempotency_key: key,
      status: "success",
      message: to_string(message)
    }
  end

  defp map_domain_result(key, {:error, "INVALID", message}) do
    %{
      idempotency_key: key,
      status: "error",
      message: "Ticket not found: #{message}"
    }
  end

  defp map_domain_result(key, {:error, code, message})
       when code in ["DUPLICATE", "DUPLICATE_TODAY", "ALREADY_INSIDE"] do
    %{
      idempotency_key: key,
      status: "error",
      message: "Already checked in: #{message}"
    }
  end

  defp map_domain_result(key, {:error, "PAYMENT_INVALID", message}) do
    %{
      idempotency_key: key,
      status: "error",
      message: "Payment invalid: #{message}"
    }
  end

  defp map_domain_result(key, {:error, "NOT_IMPLEMENTED", message}) do
    %{
      idempotency_key: key,
      status: "error",
      message: message
    }
  end

  defp map_domain_result(key, {:error, _code, message}) do
    %{
      idempotency_key: key,
      status: "error",
      message: message
    }
  end

  defp task_exit_result(scan, reason) do
    %{
      idempotency_key: Map.get(scan, "idempotency_key", "unknown"),
      status: "error",
      message: "Scan processing task failed: #{inspect(reason)}"
    }
  end

  defp emit_mobile_sync_scan_telemetry(event_id, status, duration_ms) do
    :telemetry.execute(
      [:fastcheck, :mobile_sync, :scan, :duration],
      %{duration_ms: duration_ms},
      %{event_id: event_id, status: status}
    )
  rescue
    _ -> :ok
  end

  defp emit_mobile_sync_batch_telemetry(
         event_id,
         total,
         success_count,
         duplicate_count,
         error_count,
         duration_ms
       ) do
    :telemetry.execute(
      [:fastcheck, :mobile_sync, :batch, :duration],
      %{duration_ms: duration_ms},
      %{
        event_id: event_id,
        total: total,
        success: success_count,
        duplicate: duplicate_count,
        error: error_count
      }
    )
  rescue
    _ -> :ok
  end

  # Sends a 400 Bad Request response with structured JSON error
  defp bad_request(conn, error_code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      data: nil,
      error: %{
        code: error_code,
        message: message
      }
    })
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  defp parse_since_parameter(%{"since" => since_str}) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        Logger.warning("Invalid 'since' parameter, falling back to full sync", since: since_str)
        {:ok, nil}
    end
  end

  defp parse_since_parameter(_params), do: {:ok, nil}

  defp fetch_attendees(event_id, since) do
    query =
      from attendee in Attendee,
        where: attendee.event_id == ^event_id,
        order_by: [asc: attendee.ticket_code]

    query =
      if since do
        from attendee in query, where: attendee.updated_at > ^since
      else
        query
      end

    {:ok, Repo.all(query)}
  rescue
    error ->
      {:error, error}
  end

  defp serialize_attendee(attendee) do
    %{
      id: attendee.id,
      event_id: attendee.event_id,
      ticket_code: attendee.ticket_code,
      first_name: attendee.first_name,
      last_name: attendee.last_name,
      email: attendee.email,
      ticket_type: attendee.ticket_type,
      allowed_checkins: attendee.allowed_checkins || 1,
      checkins_remaining: attendee.checkins_remaining || attendee.allowed_checkins || 1,
      payment_status: attendee.payment_status,
      is_currently_inside: attendee.is_currently_inside || false,
      checked_in_at: serialize_datetime(attendee.checked_in_at),
      checked_out_at: serialize_datetime(attendee.checked_out_at),
      updated_at: serialize_datetime(attendee.updated_at)
    }
  end

  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(datetime) when is_struct(datetime, DateTime) do
    DateTime.to_iso8601(datetime)
  end

  defp serialize_datetime(_), do: nil

  defp get_peer_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        ip |> String.split(",") |> List.first() |> String.trim()

      _ ->
        %{address: address} = Plug.Conn.get_peer_data(conn)
        :inet.ntoa(address) |> to_string()
    end
  end

  defp server_error(conn, error_code, message) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      data: nil,
      error: %{
        code: error_code,
        message: message
      }
    })
  end
end
