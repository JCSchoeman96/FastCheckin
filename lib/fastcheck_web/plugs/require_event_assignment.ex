defmodule FastCheckWeb.Plugs.RequireEventAssignment do
  @moduledoc """
  Rejects event-scoped API requests when the path event does not match the
  authenticated device session event assignment.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_device_session: session}} = conn, _opts) do
    case conn.path_params["event_id"] || conn.params["event_id"] do
      nil ->
        conn

      value ->
        case parse_int(value) do
          session_event_id when session_event_id == session.event_id ->
            conn

          _ ->
            conn
            |> put_status(:forbidden)
            |> json(%{
              data: nil,
              error: %{code: "FORBIDDEN", message: "Session is not assigned to this event"}
            })
            |> halt()
        end
    end
  end

  def call(conn, _opts), do: conn

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil
end
