defmodule FastCheckWeb.Mobile.SyncController do
  @moduledoc """
  Handles mobile client data synchronization operations.

  This controller provides endpoints for mobile scanner devices to:
  - Download attendee data for offline use (sync down)
  - Upload scanned check-ins when connectivity is restored (sync up)

  All sync operations are scoped to the authenticated event (via JWT token's
  `current_event_id`), ensuring devices can only access and modify data for
  their assigned event.

  ## Server Time Reference

  The controller returns `server_time` with all responses to help mobile
  clients track incremental sync state. Clients should use server_time
  (not device time) as the `since` parameter for subsequent syncs.

  ## Event Isolation

  All operations automatically filter by `current_event_id` from the JWT
  token, preventing cross-event data leakage.
  """

  use FastCheckWeb, :controller
  require Logger

  import Ecto.Query
  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee

  @doc """
  Returns attendee data for the authenticated event (sync down).

  This endpoint allows mobile clients to download attendee data for offline
  use. Supports both full sync (all attendees) and incremental sync (only
  attendees updated since a given timestamp).

  ## Query Parameters

  - `since` (optional) - ISO 8601 timestamp for incremental sync
    - If provided and valid, returns only attendees updated after this time
    - If invalid or not provided, returns all attendees (full sync)

  ## Success Response (200 OK)

  ```json
  {
    "server_time": "2025-11-20T10:22:30Z",
    "attendees": [
      {
        "id": 1,
        "event_id": 123,
        "ticket_code": "ABC123",
        "first_name": "John",
        "last_name": "Doe",
        "email": "john@example.com",
        "ticket_type": "General Admission",
        "allowed_checkins": 1,
        "checkins_remaining": 1,
        "payment_status": "paid",
        "is_currently_inside": false,
        "checked_in_at": null,
        "checked_out_at": null,
        "updated_at": "2025-11-20T09:15:00Z"
      }
    ],
    "count": 1,
    "sync_type": "full"
  }
  ```

  ## Error Responses

  **401 Unauthorized** - JWT token invalid or missing (handled by MobileAuth plug)

  **500 Internal Server Error** - Database error:
  ```json
  {
    "error": "sync_failed",
    "message": "Unable to retrieve attendee data"
  }
  ```

  ## Examples

      # Full sync (all attendees)
      GET /api/mobile/attendees

      # Incremental sync (attendees updated since timestamp)
      GET /api/mobile/attendees?since=2025-11-20T08:00:00Z

      # Invalid since parameter (falls back to full sync)
      GET /api/mobile/attendees?since=invalid
  """
  def get_attendees(conn, params) do
    # current_event_id is set by MobileAuth plug from verified JWT token
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
        server_time: DateTime.to_iso8601(server_time),
        attendees: Enum.map(attendees, &serialize_attendee/1),
        count: length(attendees),
        sync_type: sync_type
      })
    else
      {:error, reason} ->
        Logger.error("Mobile sync down failed",
          event_id: event_id,
          reason: inspect(reason),
          ip: get_peer_ip(conn)
        )

        server_error(
          conn,
          "sync_failed",
          "Unable to retrieve attendee data"
        )
    end
  end

  @doc """
  Accepts a batch of scanned check-ins from mobile clients (sync up).

  This endpoint processes scans that were queued on mobile devices (typically
  during offline operation) and ensures idempotent processing so duplicate
  uploads don't cause double check-ins.

  ## Request Body

  JSON payload with a `scans` array, where each scan contains:
  - `idempotency_key` (required) - Client-generated unique ID for this scan
  - `ticket_code` (required) - The ticket that was scanned
  - `direction` (required) - Either "in" or "out"
  - `scanned_at` (optional) - ISO 8601 timestamp of when scan occurred
  - `entrance_name` (optional) - Entrance where scan occurred (default: "Mobile")
  - `operator_name` (optional) - Name of operator (default: "Mobile Scanner")

  ## Success Response (200 OK)

  ```json
  {
    "results": [
      {
        "idempotency_key": "abc123",
        "status": "success",
        "message": "Check-in successful"
      },
      {
        "idempotency_key": "def456",
        "status": "duplicate",
        "message": "Already processed"
      },
      {
        "idempotency_key": "ghi789",
        "status": "error",
        "message": "Ticket not found"
      }
    ],
    "processed": 3
  }
  ```

  ## Error Responses

  **400 Bad Request** - Invalid request format:
  ```json
  {
    "error": "invalid_request",
    "message": "Request body must contain 'scans' array"
  }
  ```

  **500 Internal Server Error** - Processing failed

  ## Examples

      POST /api/mobile/scans
      {
        "scans": [
          {
            "idempotency_key": "mobile-1234-5678",
            "ticket_code": "ABC123",
            "direction": "in",
            "scanned_at": "2025-11-20T10:15:00Z",
            "entrance_name": "Main Gate"
          }
        ]
      }
  """
  def upload_scans(conn, %{"scans" => scans}) when is_list(scans) do
    # current_event_id is set by MobileAuth plug from verified JWT token
    event_id = conn.assigns.current_event_id

    Logger.info("Mobile scan upload started",
      event_id: event_id,
      scan_count: length(scans),
      ip: get_peer_ip(conn)
    )

    results = Enum.map(scans, fn scan -> process_scan(event_id, scan) end)

    success_count = Enum.count(results, &(&1.status == "success"))
    duplicate_count = Enum.count(results, &(&1.status == "duplicate"))
    error_count = Enum.count(results, &(&1.status == "error"))

    Logger.info("Mobile scan upload completed",
      event_id: event_id,
      total: length(results),
      success: success_count,
      duplicate: duplicate_count,
      error: error_count,
      ip: get_peer_ip(conn)
    )

    json(conn, %{
      results: results,
      processed: length(results)
    })
  end

  def upload_scans(conn, _params) do
    bad_request(conn, "invalid_request", "Request body must contain 'scans' array")
  end

  # ========================================================================
  # Scan Processing Helpers
  # ========================================================================

  # Processes a single scan with idempotency checking.
  #
  # Flow:
  # 1. Validate scan structure
  # 2. Check idempotency log (have we seen this before?)
  # 3. If duplicate → return stored result
  # 4. If new → delegate to check-in/out logic
  # 5. Record result in idempotency log
  # 6. Return result to client
  defp process_scan(event_id, scan) do
    with {:ok, validated_scan} <- validate_scan(scan),
         {:ok, result} <- check_or_process_scan(event_id, validated_scan) do
      result
    else
      {:error, reason} ->
        %{
          idempotency_key: scan["idempotency_key"] || "unknown",
          status: "error",
          message: reason
        }
    end
  end

  # Validates that a scan has all required fields.
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

  # Extracts a required field from the scan map.
  defp extract_field(scan, field) do
    case Map.get(scan, field) do
      nil -> {:error, "Missing required field: #{field}"}
      "" -> {:error, "Empty value for required field: #{field}"}
      value -> {:ok, value}
    end
  end

  # Validates that direction is either "in" or "out".
  defp validate_direction("in"), do: :ok
  defp validate_direction("out"), do: :ok

  defp validate_direction(invalid),
    do: {:error, "Invalid direction: #{invalid}. Must be 'in' or 'out'"}

  # Checks idempotency log and either returns cached result or processes scan.
  defp check_or_process_scan(event_id, scan) do
    case check_idempotency(event_id, scan.idempotency_key) do
      {:cached, stored_result} ->
        # This scan was already processed - return stored result
        {:ok,
         %{
           idempotency_key: scan.idempotency_key,
           status: "duplicate",
           message: "Already processed: #{stored_result}"
         }}

      :new ->
        # First time seeing this scan - process it
        execute_scan(event_id, scan)
    end
  end

  # Checks if a scan has been processed before via idempotency log.
  #
  # Returns:
  # - {:cached, result} if scan was already processed
  # - :new if this is the first time seeing this scan
  defp check_idempotency(event_id, idempotency_key) do
    query =
      from l in FastCheck.Mobile.MobileIdempotencyLog,
        where: l.event_id == ^event_id and l.idempotency_key == ^idempotency_key,
        select: l.result

    case Repo.one(query) do
      nil -> :new
      result -> {:cached, result}
    end
  end

  # Executes the actual scan processing (check-in or check-out).
  defp execute_scan(event_id, scan) do
    # Delegate to appropriate domain function
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
          # Check-out functionality to be implemented in future
          {:error, "NOT_IMPLEMENTED", "Check-out functionality not yet available"}
      end

    # Map domain result to API response and record in idempotency log
    api_result = map_domain_result(scan.idempotency_key, domain_result)
    record_idempotency(event_id, scan, api_result)

    {:ok, api_result}
  end

  # Maps domain function results to API response format.
  defp map_domain_result(key, {:ok, _attendee, "SUCCESS"}) do
    %{
      idempotency_key: key,
      status: "success",
      message: "Check-in successful"
    }
  end

  defp map_domain_result(key, {:error, "INVALID", message}) do
    %{
      idempotency_key: key,
      status: "error",
      message: "Ticket not found: #{message}"
    }
  end

  defp map_domain_result(key, {:error, "DUPLICATE", message}) do
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

  # Records the scan result in the idempotency log for future duplicate detection.
  defp record_idempotency(event_id, scan, result) do
    attrs = %{
      event_id: event_id,
      idempotency_key: scan.idempotency_key,
      ticket_code: scan.ticket_code,
      result: result.status,
      metadata: %{
        message: result.message,
        direction: scan.direction,
        scanned_at: scan.scanned_at,
        processed_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    %FastCheck.Mobile.MobileIdempotencyLog{}
    |> FastCheck.Mobile.MobileIdempotencyLog.changeset(attrs)
    |> Repo.insert()

    # We ignore errors here because:
    # 1. The scan has already been processed
    # 2. If insert fails due to duplicate key, that's fine (race condition)
    # 3. Next upload will still check the log first
    :ok
  rescue
    _error ->
      Logger.warning("Failed to record idempotency log",
        event_id: event_id,
        idempotency_key: scan.idempotency_key
      )

      :ok
  end

  # Sends a 400 Bad Request response with structured JSON error
  defp bad_request(conn, error_code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: error_code,
      message: message
    })
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # Parses the optional 'since' query parameter for incremental sync.
  #
  # Returns:
  # - {:ok, nil} if not provided (full sync)
  # - {:ok, datetime} if valid ISO 8601 timestamp
  # - {:ok, nil} if invalid (falls back to full sync with warning)
  defp parse_since_parameter(%{"since" => since_str}) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        Logger.warning("Invalid 'since' parameter, falling back to full sync",
          since: since_str
        )

        {:ok, nil}
    end
  end

  defp parse_since_parameter(_params), do: {:ok, nil}

  # Fetches attendees for the given event, optionally filtered by update time.
  #
  # Parameters:
  # - event_id: The event to fetch attendees for
  # - since: Optional datetime to filter by updated_at
  #
  # Returns:
  # - {:ok, [attendee]} on success
  # - {:error, reason} on database error
  defp fetch_attendees(event_id, since) do
    query =
      from a in Attendee,
        where: a.event_id == ^event_id,
        order_by: [asc: a.ticket_code]

    query =
      if since do
        from a in query, where: a.updated_at > ^since
      else
        query
      end

    {:ok, Repo.all(query)}
  rescue
    error ->
      {:error, error}
  end

  # Serializes an Attendee struct to JSON-friendly map with all fields
  # needed by the mobile client.
  #
  # The mobile client needs:
  # - Identity: id, event_id, ticket_code
  # - Person info: first_name, last_name, email
  # - Ticket info: ticket_type, payment_status
  # - Check-in state: allowed_checkins, checkins_remaining, is_currently_inside
  # - Timestamps: checked_in_at, checked_out_at, updated_at
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

  # Serializes a DateTime to ISO 8601 string or returns null.
  defp serialize_datetime(nil), do: nil

  defp serialize_datetime(datetime) when is_struct(datetime, DateTime) do
    DateTime.to_iso8601(datetime)
  end

  defp serialize_datetime(_), do: nil

  # Helper: Get peer IP address for logging (handles proxies)
  defp get_peer_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        ip |> String.split(",") |> List.first() |> String.trim()

      _ ->
        case Plug.Conn.get_peer_data(conn) do
          %{address: address} -> :inet.ntoa(address) |> to_string()
          _ -> "unknown"
        end
    end
  end

  # Sends a 500 Internal Server Error response with structured JSON error
  defp server_error(conn, error_code, message) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      error: error_code,
      message: message
    })
  end
end
