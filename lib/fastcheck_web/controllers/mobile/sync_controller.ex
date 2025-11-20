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

  This endpoint will be implemented in a future step to handle:
  - Batch upload of offline scans
  - Idempotency checking via idempotency_key
  - Processing check-ins through the Attendees context
  - Returning results for each scan in the batch

  Currently returns a placeholder response.
  """
  def upload_scans(conn, _params) do
    # Placeholder for future implementation
    json(conn, %{
      error: "not_implemented",
      message: "Scan upload endpoint not yet implemented"
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
