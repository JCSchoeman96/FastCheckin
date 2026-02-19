defmodule FastCheckWeb.Plugs.ScannerAuth do
  @moduledoc """
  Protects scanner-only browser routes with an event-scoped scanner session.

  A valid scanner session must:

  1. be authenticated via scanner login,
  2. include a scanner event_id,
  3. match the route event_id,
  4. reference an event that still exists and is scannable.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias FastCheck.Events
  alias FastCheck.Events.Event

  use FastCheckWeb, :verified_routes

  @scanner_authenticated_key :scanner_authenticated
  @scanner_event_id_key :scanner_event_id
  @scanner_event_name_key :scanner_event_name
  @scanner_operator_name_key :scanner_operator_name

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    with true <- scanner_authenticated?(conn),
         {:ok, session_event_id} <- parse_event_id(get_session(conn, @scanner_event_id_key)),
         {:ok, route_event_id} <- parse_route_event_id(conn),
         true <- session_event_id == route_event_id,
         {:ok, %Event{} = event} <- fetch_event(route_event_id),
         :ok <- ensure_event_scannable(event) do
      assign_current_scanner(conn, event, session_event_id)
    else
      _reason ->
        conn
        |> clear_scanner_session()
        |> redirect(to: scanner_login_redirect_path(conn))
        |> halt()
    end
  end

  defp scanner_authenticated?(conn) do
    get_session(conn, @scanner_authenticated_key) == true
  end

  defp parse_route_event_id(conn) do
    conn.path_params
    |> Map.get("event_id")
    |> parse_event_id()
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {event_id, ""} when event_id > 0 -> {:ok, event_id}
      _ -> :error
    end
  end

  defp parse_event_id(_), do: :error

  defp fetch_event(event_id) do
    {:ok, Events.get_event!(event_id)}
  rescue
    Ecto.NoResultsError -> :error
  end

  defp ensure_event_scannable(%Event{} = event) do
    case Events.can_check_in?(event) do
      {:ok, _state} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp assign_current_scanner(conn, event, event_id) do
    scanner =
      %{
        event_id: event_id,
        event_name: get_session(conn, @scanner_event_name_key) || event.name,
        operator_name: get_session(conn, @scanner_operator_name_key)
      }

    assign(conn, :current_scanner, scanner)
  end

  defp clear_scanner_session(conn) do
    conn
    |> delete_session(@scanner_authenticated_key)
    |> delete_session(@scanner_event_id_key)
    |> delete_session(@scanner_event_name_key)
    |> delete_session(@scanner_operator_name_key)
  end

  defp scanner_login_redirect_path(conn) do
    redirect_target =
      case conn.query_string do
        "" -> conn.request_path
        query_string -> conn.request_path <> "?" <> query_string
      end

    ~p"/scanner/login?redirect_to=#{redirect_target}"
  end
end
