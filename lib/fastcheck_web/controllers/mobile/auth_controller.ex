defmodule FastCheckWeb.Mobile.AuthController do
  @moduledoc """
  Handles mobile scanner device authentication and JWT token issuance.

  This controller provides a simple authentication mechanism for mobile
  scanner devices to obtain JWT tokens for accessing event data and
  submitting scans.

  ## Authentication Mechanism

  Mobile devices authenticate by providing an event_id. The controller:
  1. Validates the event exists and is accessible
  2. Generates a JWT token scoped to that event
  3. Returns the token along with event metadata

  This approach keeps authentication simple while ensuring devices can
  only access data for the specific event they're authenticated against.

  ## Endpoints

  - `POST /api/mobile/login` - Authenticate device and obtain JWT token

  ## Security Considerations

  - Event IDs are not secret, but they provide event-level isolation
  - JWTs expire after a configured TTL (default 24 hours)
  - Each JWT is scoped to a single event_id via the token claims
  - The mobile API endpoints verify the JWT on every request
  """

  use FastCheckWeb, :controller
  require Logger

  alias FastCheck.Events
  alias FastCheck.Mobile.Token

  @doc """
  Authenticates a mobile scanner device and issues a JWT token.

  This endpoint accepts an event_id and returns a JWT token that grants
  access to that event's data. The token includes the event_id in its
  claims, ensuring all subsequent API calls are properly scoped.

  ## Request Body

  JSON payload with the following fields:
  - `event_id` (required) - The ID of the event to authenticate against

  ## Success Response (200 OK)

  ```json
  {
    "token": "eyJhbGciOiJIUzI1NiIs...",
    "event_id": 123,
    "event_name": "Summer Festival 2025",
    "expires_in": 86400
  }
  ```

  ## Error Responses

  **400 Bad Request** - Missing or invalid event_id:
  ```json
  {
    "error": "invalid_request",
    "message": "event_id is required and must be a positive integer"
  }
  ```

  **404 Not Found** - Event not found:
  ```json
  {
    "error": "event_not_found",
    "message": "Event with ID 123 does not exist"
  }
  ```

  **500 Internal Server Error** - Token generation failed:
  ```json
  {
    "error": "token_generation_failed",
    "message": "Unable to generate authentication token"
  }
  ```

  ## Examples

      # Valid authentication
      POST /api/mobile/login
      {
        "event_id": 123
      }

      # Response
      {
        "token": "eyJ...",
        "event_id": 123,
        "event_name": "Concert 2025",
        "expires_in": 86400
      }

      # Invalid event_id
      POST /api/mobile/login
      {
        "event_id": "invalid"
      }

      # Response
      {
        "error": "invalid_request",
        "message": "event_id is required and must be a positive integer"
      }
  """
  def login(conn, params) do
    with {:ok, event_id} <- extract_event_id(params),
         {:ok, event} <- fetch_event(event_id),
         {:ok, token} <- Token.issue_scanner_token(event_id) do
      # Authentication successful - return token and event metadata
      Logger.info("Mobile scanner authenticated",
        event_id: event_id,
        event_name: event.name,
        ip: get_peer_ip(conn)
      )

      json(conn, %{
        token: token,
        event_id: event.id,
        event_name: event.name,
        expires_in: Token.token_ttl_seconds()
      })
    else
      {:error, :missing_event_id} ->
        bad_request(conn, "invalid_request", "event_id is required")

      {:error, :invalid_event_id} ->
        bad_request(
          conn,
          "invalid_request",
          "event_id must be a positive integer"
        )

      {:error, :event_not_found, event_id} ->
        Logger.warning("Mobile login attempted for non-existent event",
          event_id: event_id,
          ip: get_peer_ip(conn)
        )

        not_found(conn, "event_not_found", "Event with ID #{event_id} does not exist")

      {:error, reason} ->
        Logger.error("Token generation failed during mobile login",
          reason: inspect(reason),
          ip: get_peer_ip(conn)
        )

        server_error(
          conn,
          "token_generation_failed",
          "Unable to generate authentication token"
        )
    end
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # Extracts and validates event_id from request parameters.
  #
  # Returns:
  # - {:ok, event_id} if valid positive integer
  # - {:error, :missing_event_id} if not present
  # - {:error, :invalid_event_id} if present but invalid
  defp extract_event_id(%{"event_id" => event_id}) when is_integer(event_id) and event_id > 0 do
    {:ok, event_id}
  end

  defp extract_event_id(%{"event_id" => event_id}) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_event_id}
    end
  end

  defp extract_event_id(%{"event_id" => _}), do: {:error, :invalid_event_id}

  defp extract_event_id(_params), do: {:error, :missing_event_id}

  # Fetches the event from the database.
  #
  # Returns:
  # - {:ok, event} if event exists
  # - {:error, :event_not_found, event_id} if event does not exist
  defp fetch_event(event_id) do
    case Events.get_event!(event_id) do
      nil ->
        {:error, :event_not_found, event_id}

      event ->
        {:ok, event}
    end
  rescue
    Ecto.NoResultsError ->
      {:error, :event_not_found, event_id}
  end

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

  # Sends a 400 Bad Request response with structured JSON error
  defp bad_request(conn, error_code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: error_code,
      message: message
    })
  end

  # Sends a 404 Not Found response with structured JSON error
  defp not_found(conn, error_code, message) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: error_code,
      message: message
    })
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
