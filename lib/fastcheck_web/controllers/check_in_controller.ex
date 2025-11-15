defmodule FastCheckWeb.CheckInController do
  use FastCheckWeb, :controller

  alias FastCheck.Attendees

  @doc """
  Processes a ticket scan via the JSON API.
  """
  def create(conn, params) do
    with {:ok, event_id} <- parse_event_id(Map.get(params, "event_id")),
         {:ok, ticket_code} <- fetch_ticket_code(Map.get(params, "ticket_code")),
         {:ok, attendee, status} <-
           Attendees.check_in(
             event_id,
             ticket_code,
             Map.get(params, "entrance_name", "Main"),
             Map.get(params, "operator_name")
           ) do
      json(conn, %{
        status: status,
        ticket_code: attendee.ticket_code,
        attendee_id: attendee.id,
        checkins_remaining: attendee.checkins_remaining
      })
    else
      {:error, :invalid_event_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "INVALID_EVENT", message: "event_id must be an integer"})

      {:error, :missing_ticket_code} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "INVALID_TICKET", message: "ticket_code is required"})

      {:error, code, message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: code, message: message})
    end
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_event_id}
    end
  end

  defp parse_event_id(_), do: {:error, :invalid_event_id}

  defp fetch_ticket_code(code) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed == "" do
      {:error, :missing_ticket_code}
    else
      {:ok, trimmed}
    end
  end

  defp fetch_ticket_code(_), do: {:error, :missing_ticket_code}
end
