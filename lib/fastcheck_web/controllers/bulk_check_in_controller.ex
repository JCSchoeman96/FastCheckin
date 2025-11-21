defmodule FastCheckWeb.BulkCheckInController do
  use FastCheckWeb, :controller

  alias FastCheck.Attendees

  @doc """
  Processes a batch of ticket scans via the JSON API.
  """
  def create(conn, %{"scans" => scans} = params) when is_list(scans) do
    # Try to get event_id from top-level params first
    case parse_event_id(params["event_id"]) do
      {:ok, event_id} ->
        results =
          Enum.map(scans, fn scan_params ->
            process_scan(event_id, scan_params)
          end)

        json(conn, %{data: %{results: results}, error: nil})

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          data: nil,
          error: %{code: "INVALID_EVENT", message: "Valid event_id is required at top level"}
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      data: nil,
      error: %{code: "INVALID_PAYLOAD", message: "Request must include a 'scans' array"}
    })
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

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_event_id}
    end
  end

  defp parse_event_id(_), do: {:error, :invalid_event_id}
end
