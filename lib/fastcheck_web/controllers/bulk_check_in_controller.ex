defmodule FastCheckWeb.BulkCheckInController do
  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  alias FastCheck.Attendees

  @doc """
  Processes a batch of ticket scans via the JSON API.
  """
  def create(conn, %{"scans" => scans}) when is_list(scans) do
    with {:ok, event_id} <- fetch_event_id(conn) do
      results =
        Enum.map(scans, fn scan_params ->
          process_scan(event_id, scan_params)
        end)

      json(conn, %{data: %{results: results}, error: nil})
    end
  end

  def create(_conn, _params) do
    {:error, "INVALID_PAYLOAD", "Request must include a 'scans' array"}
  end

  defp process_scan(event_id, scan_params) do
    ticket_code = Map.get(scan_params, "ticket_code")
    entrance = Map.get(scan_params, "entrance_name", "Main")
    operator = Map.get(scan_params, "operator_name")

    if is_binary(ticket_code) do
      case Attendees.check_in(event_id, ticket_code, entrance, operator) do
        {:ok, attendee, status} ->
          %{
            ticket_code: ticket_code,
            status: status,
            attendee_id: attendee.id,
            checkins_remaining: attendee.checkins_remaining
          }

        {:error, code, message} ->
          %{
            ticket_code: ticket_code,
            status: "ERROR",
            error_code: code,
            message: message
          }
      end
    else
      %{
        ticket_code: nil,
        status: "ERROR",
        error_code: "MISSING_TICKET_CODE",
        message: "Ticket code is required"
      }
    end
  end

  defp fetch_event_id(%{assigns: %{current_event_id: event_id}})
       when is_integer(event_id) and event_id > 0,
       do: {:ok, event_id}

  defp fetch_event_id(_), do: {:error, :unauthorized}
end
