defmodule FastCheck.Scans.LegacyUploadService do
  @moduledoc """
  Legacy Postgres-backed mobile upload implementation preserved behind the new
  ingestion service.
  """

  import Ecto.Query

  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo
  alias FastCheck.Scans.Validator

  @idempotency_pending_result "__pending__"
  @idempotency_poll_attempts 10
  @idempotency_poll_interval_ms 25
  @idempotency_pending_stale_multiplier 2
  @idempotency_pending_stale_floor_ms 15_000
  @default_task_timeout_ms 10_000

  @spec upload_batch(integer(), list()) :: {:ok, [map()]}
  def upload_batch(event_id, scans) when is_integer(event_id) and is_list(scans) do
    {:ok, Enum.map(scans, &process_scan(event_id, &1))}
  end

  defp process_scan(event_id, scan) do
    with {:ok, validated_scan} <- Validator.validate(event_id, scan),
         {:ok, reservation_status} <- reserve_idempotency(validated_scan),
         {:ok, processed_result} <- process_reserved_scan(validated_scan, reservation_status) do
      processed_result
    else
      {:error, reason} ->
        %{
          idempotency_key: Map.get(scan, "idempotency_key", "unknown"),
          status: "error",
          message: reason
        }
    end
  end

  defp reserve_idempotency(scan) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    values = [
      %{
        event_id: scan.event_id,
        idempotency_key: scan.idempotency_key,
        ticket_code: scan.ticket_code,
        result: @idempotency_pending_result,
        metadata: %{
          "status" => "pending",
          "direction" => scan.direction,
          "scanned_at" => serialize_datetime(scan.scanned_at),
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
    _exception ->
      {:error, "Unable to reserve scan idempotency record"}
  end

  defp process_reserved_scan(scan, :reserved) do
    with {:ok, api_result} <- execute_scan(scan),
         :ok <- persist_idempotency_result(scan, api_result) do
      {:ok, api_result}
    end
  end

  defp process_reserved_scan(scan, :duplicate) do
    case await_idempotency_result(scan.event_id, scan.idempotency_key, @idempotency_poll_attempts) do
      {:ok, %{result: @idempotency_pending_result} = row} ->
        handle_pending_duplicate(scan, row)

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

  defp handle_pending_duplicate(scan, row) do
    if pending_stale?(row) do
      _ = release_pending_reservation(scan.event_id, scan.idempotency_key)
      {:error, "Previous scan attempt timed out. Please retry."}
    else
      {:error, "Scan is still being processed. Retry shortly."}
    end
  end

  defp pending_stale?(%{updated_at: %DateTime{} = updated_at}) do
    stale_after_ms =
      max(
        @default_task_timeout_ms * @idempotency_pending_stale_multiplier,
        @idempotency_pending_stale_floor_ms
      )

    DateTime.diff(DateTime.utc_now(), updated_at, :millisecond) >= stale_after_ms
  end

  defp pending_stale?(_row), do: true

  defp release_pending_reservation(event_id, idempotency_key) do
    query =
      from log in MobileIdempotencyLog,
        where:
          log.event_id == ^event_id and
            log.idempotency_key == ^idempotency_key and
            log.result == ^@idempotency_pending_result

    Repo.delete_all(query)
    :ok
  rescue
    _exception -> :ok
  end

  defp persist_idempotency_result(scan, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from log in MobileIdempotencyLog,
        where: log.event_id == ^scan.event_id and log.idempotency_key == ^scan.idempotency_key

    Repo.update_all(query,
      set: [
        result: result.status,
        metadata: %{
          "status" => result.status,
          "message" => result.message,
          "direction" => scan.direction,
          "scanned_at" => serialize_datetime(scan.scanned_at),
          "processed_at" => DateTime.to_iso8601(now)
        },
        updated_at: now
      ]
    )

    :ok
  rescue
    _exception ->
      :ok
  end

  defp execute_scan(scan) do
    domain_result =
      case scan.direction do
        "in" ->
          FastCheck.Attendees.check_in(
            scan.event_id,
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
    %{idempotency_key: key, status: "success", message: "Check-in successful"}
  end

  defp map_domain_result(key, {:ok, _attendee, message}) do
    %{idempotency_key: key, status: "success", message: to_string(message)}
  end

  defp map_domain_result(key, {:error, "INVALID", message}) do
    %{idempotency_key: key, status: "error", message: "Ticket not found: #{message}"}
  end

  defp map_domain_result(key, {:error, code, message})
       when code in ["DUPLICATE", "DUPLICATE_TODAY", "ALREADY_INSIDE"] do
    %{idempotency_key: key, status: "error", message: "Already checked in: #{message}"}
  end

  defp map_domain_result(key, {:error, "PAYMENT_INVALID", message}) do
    %{idempotency_key: key, status: "error", message: "Payment invalid: #{message}"}
  end

  defp map_domain_result(key, {:error, "NOT_IMPLEMENTED", message}) do
    %{idempotency_key: key, status: "error", message: message}
  end

  defp map_domain_result(key, {:error, _code, message}) do
    %{idempotency_key: key, status: "error", message: message}
  end

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
