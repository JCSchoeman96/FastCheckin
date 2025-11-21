defmodule FastCheckWeb.CheckInController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

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
        data: %{
          status: status,
          ticket_code: attendee.ticket_code,
          attendee_id: attendee.id,
          checkins_remaining: attendee.checkins_remaining
        },
        error: nil
      })
    end
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, "INVALID_EVENT", "event_id must be a positive integer"}
    end
  end

  defp parse_event_id(_), do: {:error, "INVALID_EVENT", "event_id must be a positive integer"}

  defp fetch_ticket_code(code) when is_binary(code) do
    trimmed = String.trim(code)

    if trimmed == "" do
      {:error, "INVALID_TICKET", "ticket_code is required"}
    else
      {:ok, trimmed}
    end
  end

  defp fetch_ticket_code(_), do: {:error, "INVALID_TICKET", "ticket_code is required"}
end
