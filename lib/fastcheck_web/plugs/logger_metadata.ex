defmodule FastCheckWeb.Plugs.LoggerMetadata do
  @moduledoc """
  Plug to set useful Logger metadata for request tracing.

  Sets metadata including:
  - request_id (Phoenix default)
  - event_id (from JWT claims or params)
  - user_id (from session/JWT)
  - ip (client IP address)
  - device_id (from JWT claims for mobile API)

  Usage in router:
      plug FastCheckWeb.Plugs.LoggerMetadata
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Extract IP address
    ip = get_client_ip(conn)
    Logger.metadata(ip: ip)

    # Try to extract event_id from multiple sources
    event_id = extract_event_id(conn)

    if event_id do
      Logger.metadata(event_id: event_id)
    end

    # Try to extract device_id from JWT (mobile API)
    device_id = extract_device_id(conn)

    if device_id do
      Logger.metadata(device_id: device_id)
    end

    # Extract user_id if available (from assigns, set by auth pipeline)
    if conn.assigns[:current_user] do
      Logger.metadata(user_id: conn.assigns.current_user.id)
    end

    conn
  end

  # Extract event_id from JWT claims, params, or session
  defp extract_event_id(conn) do
    cond do
      # From assigned authenticated context
      is_integer(conn.assigns[:current_event_id]) ->
        conn.assigns.current_event_id

      # From JWT claims (mobile API)
      jwt_claims = conn.assigns[:jwt_claims] ->
        jwt_claims["event_id"]

      token_claims = conn.assigns[:token_claims] ->
        token_claims["event_id"]

      # From query params or body params
      conn.params["event_id"] ->
        parse_int(conn.params["event_id"])

      # From session
      session_fetched?(conn) and get_session(conn, :current_event_id) ->
        get_session(conn, :current_event_id)

      true ->
        nil
    end
  end

  # Extract device_id from JWT claims
  defp extract_device_id(conn) do
    cond do
      token_claims = conn.assigns[:token_claims] -> token_claims["device_id"]
      jwt_claims = conn.assigns[:jwt_claims] -> jwt_claims["device_id"]
      true -> nil
    end
  end

  # Get client IP address
  defp get_client_ip(conn) do
    # Check X-Forwarded-For header first (for proxied requests)
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        # Take the first IP in the chain
        ip
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fallback to remote_ip
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_), do: nil

  defp session_fetched?(conn) do
    Map.get(conn.private, :plug_session_fetch) == :done
  end
end
