defmodule FastCheckWeb.CheckInController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.Attendees

  @doc """
  Processes a ticket scan via the JSON API.
  """
  def create(conn, params) do
    with {:ok, event_id} <- fetch_event_id(conn),
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

  defp fetch_event_id(%{assigns: %{current_event_id: event_id}})
       when is_integer(event_id) and event_id > 0,
       do: {:ok, event_id}

  defp fetch_event_id(_), do: {:error, :unauthorized}

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
