defmodule FastCheckWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates the new native scanner API using revocable device sessions.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias FastCheck.Devices

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, %{device: device, session: session, token_claims: claims}} <-
           Devices.authenticate_bearer(token) do
      conn
      |> assign(:current_device, device)
      |> assign(:current_device_session, session)
      |> assign(:current_event_id, session.event_id)
      |> assign(:token_claims, claims)
    else
      {:error, :forbidden} ->
        deny(conn, :forbidden, "FORBIDDEN", "Device session has been revoked")

      {:error, _reason} ->
        deny(conn, :unauthorized, "UNAUTHORIZED", "Valid device session required")
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> {:ok, token}
      _ -> {:error, :missing_bearer}
    end
  end

  defp deny(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{data: nil, error: %{code: code, message: message}})
    |> halt()
  end
end
