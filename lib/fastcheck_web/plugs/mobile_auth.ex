defmodule FastCheckWeb.Plugs.MobileAuth do
  @moduledoc """
  Authentication plug for mobile API requests using JWT tokens.

  This plug validates JWT tokens from the Authorization header and attaches
  the authenticated event context to the connection for use by downstream
  controllers and business logic.

  ## Usage

  Add this plug to the `:mobile_api` pipeline in your router:

      pipeline :mobile_api do
        plug :accepts, ["json"]
        plug FastCheckWeb.Plugs.MobileAuth
      end

      scope "/api/mobile", FastCheckWeb.Mobile do
        pipe_through :mobile_api

        get "/attendees", SyncController, :get_attendees
        post "/scans", SyncController, :upload_scans
      end

  ## Token Verification

  The plug performs the following steps:
  1. Extracts the `Authorization: Bearer <token>` header
  2. Verifies the token using `FastCheck.Mobile.Token`
  3. Extracts `event_id` and `role` from verified claims
  4. Assigns `:current_event_id` and `:current_role` to the connection

  ## Error Handling

  If authentication fails, the plug halts the connection with an HTTP 401
  JSON response. The specific error type is included in the response:

  - **Missing Authorization header**: No token provided
  - **Invalid token format**: Bearer scheme missing or malformed
  - **Token expired**: Token has passed expiration time
  - **Invalid signature**: Token signature verification failed
  - **Malformed token**: Token structure is invalid
  - **Missing claims**: Required claims (event_id, role) are absent

  ## Security Notes

  - The plug **never** reads `event_id` from query parameters or request body
  - All event context is derived exclusively from the verified JWT token
  - The plug performs no business logic or database queries
  - It is designed to be reusable across all `/api/mobile` routes

  ## Examples

      # Successful authentication
      conn = conn
        |> put_req_header("authorization", "Bearer valid_jwt_token")
        |> FastCheckWeb.Plugs.MobileAuth.call([])

      conn.assigns.current_event_id  # => 123
      conn.assigns.current_role      # => "scanner"

      # Missing header
      conn = conn
        |> FastCheckWeb.Plugs.MobileAuth.call([])

      # Returns 401 with error: "missing_authorization_header"

      # Expired token
      conn = conn
        |> put_req_header("authorization", "Bearer expired_token")
        |> FastCheckWeb.Plugs.MobileAuth.call([])

      # Returns 401 with error: "token_expired"
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  require Logger

  alias FastCheck.Mobile.Token

  # ========================================================================
  # Plug Callbacks
  # ========================================================================

  @doc """
  Initializes the plug with options.

  Currently no options are supported, but the interface is provided
  for future extensibility (e.g., custom error handlers).
  """
  def init(opts), do: opts

  @doc """
  Authenticates the mobile API request using JWT token from Authorization header.

  This is the main plug callback that performs token verification and
  assigns authenticated context to the connection.

  ## Steps

  1. Extract Authorization header
  2. Parse Bearer token
  3. Verify token signature and claims
  4. Extract event_id and role from claims
  5. Assign to connection or halt with 401

  ## Parameters

  - `conn` - The Plug.Conn struct
  - `_opts` - Plug options (currently unused)

  ## Returns

  - Updated conn with assigns on success
  - Halted conn with 401 JSON response on failure
  """
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, claims} <- Token.verify_token(token),
         {:ok, event_id} <- Token.extract_event_id(claims),
         {:ok, role} <- Token.extract_role(claims) do
      # Authentication successful - attach context to connection
      conn
      |> assign(:current_event_id, event_id)
      |> assign(:current_role, role)
      |> assign(:token_claims, claims)
    else
      {:error, :missing_authorization_header} ->
        unauthorized(conn, "missing_authorization_header", "Authorization header is required")

      {:error, :invalid_bearer_format} ->
        unauthorized(
          conn,
          "invalid_bearer_format",
          "Authorization header must be 'Bearer <token>'"
        )

      {:error, :expired} ->
        unauthorized(conn, "token_expired", "Token has expired, please re-authenticate")

      {:error, :invalid_signature} ->
        unauthorized(conn, "invalid_signature", "Token signature is invalid")

      {:error, :malformed} ->
        unauthorized(conn, "malformed_token", "Token structure is invalid")

      {:error, :missing_claims} ->
        unauthorized(conn, "missing_claims", "Token is missing required claims (event_id, role)")

      {:error, :missing_event_id} ->
        unauthorized(conn, "missing_event_id", "Token does not contain event_id claim")

      {:error, :missing_role} ->
        unauthorized(conn, "missing_role", "Token does not contain role claim")

      {:error, reason} ->
        # Catch-all for unexpected errors
        Logger.error("Unexpected authentication error: #{inspect(reason)}")
        unauthorized(conn, "authentication_failed", "Authentication failed")
    end
  end

  # ========================================================================
  # Private Helpers
  # ========================================================================

  # Extracts the JWT token from the Authorization header.
  #
  # Expected format: "Bearer <token>"
  #
  # Returns:
  # - {:ok, token} if header is present and well-formed
  # - {:error, :missing_authorization_header} if header is absent
  # - {:error, :invalid_bearer_format} if format is incorrect
  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, :missing_authorization_header}

      [auth_header | _] ->
        case String.split(auth_header, " ", parts: 2) do
          ["Bearer", token] when byte_size(token) > 0 ->
            {:ok, token}

          _ ->
            {:error, :invalid_bearer_format}
        end
    end
  end

  # Sends an HTTP 401 Unauthorized response with structured JSON error.
  #
  # The response includes:
  # - error: machine-readable error code
  # - message: human-readable error description
  #
  # The connection is halted to prevent further downstream processing.
  defp unauthorized(conn, error_code, message) do
    Logger.warning("Mobile API authentication failed",
      error: error_code,
      path: conn.request_path,
      ip: get_peer_ip(conn)
    )

    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: error_code,
      message: message
    })
    |> halt()
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
end
