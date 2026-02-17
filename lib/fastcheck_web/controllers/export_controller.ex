defmodule FastCheckWeb.ExportController do
  @moduledoc """
  Handles CSV exports for attendees and check-ins.
  """
  use FastCheckWeb, :controller

  alias FastCheck.{Attendees, Events}

  @doc """
  Exports attendees for an event as CSV.
  """
  def export_attendees(conn, %{"event_id" => event_id_param}) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, %Events.Event{} = event} <- fetch_event(event_id) do
      attendees = Attendees.list_event_attendees(event_id)

      csv_content = generate_attendees_csv(attendees)
      filename = "#{sanitize_filename(event.name)}_attendees_#{date_suffix()}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, csv_content)
    else
      {:error, :event_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Event not found"})

      {:error, :invalid_event_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid event ID"})
    end
  end

  def export_attendees(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing event_id parameter"})
  end

  @doc """
  Exports check-ins for an event as CSV.
  """
  def export_check_ins(conn, %{"event_id" => event_id_param}) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, %Events.Event{}} <- fetch_event(event_id) do
      check_ins = Attendees.list_event_check_ins(event_id)

      csv_content = generate_check_ins_csv(check_ins)
      filename = "check_ins_#{event_id}_#{date_suffix()}.csv"

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
      |> send_resp(200, csv_content)
    else
      {:error, :event_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Event not found"})

      {:error, :invalid_event_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid event ID"})
    end
  end

  def export_check_ins(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing event_id parameter"})
  end

  # Private Helpers

  defp parse_event_id(event_id) when is_integer(event_id), do: {:ok, event_id}

  defp parse_event_id(event_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_event_id}
    end
  end

  defp parse_event_id(_), do: {:error, :invalid_event_id}

  defp fetch_event(event_id) do
    {:ok, Events.get_event!(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :event_not_found}
  end

  defp generate_attendees_csv(attendees) do
    headers = [
      "Ticket Code",
      "First Name",
      "Last Name",
      "Email",
      "Ticket Type",
      "Payment Status",
      "Checked In At",
      "Last Checked In At",
      "Checked Out At",
      "Check-ins Remaining",
      "Allowed Check-ins"
    ]

    rows =
      Enum.map(attendees, fn attendee ->
        [
          attendee.ticket_code || "",
          attendee.first_name || "",
          attendee.last_name || "",
          attendee.email || "",
          attendee.ticket_type || "",
          attendee.payment_status || "",
          format_datetime(attendee.checked_in_at),
          format_datetime(attendee.last_checked_in_at),
          format_datetime(attendee.checked_out_at),
          to_string(attendee.checkins_remaining || 0),
          to_string(attendee.allowed_checkins || 1)
        ]
      end)

    [headers | rows]
    |> Enum.map(&encode_csv_row/1)
    |> Enum.join("\n")
  end

  defp generate_check_ins_csv(check_ins) do
    headers = [
      "Ticket Code",
      "Attendee Name",
      "Scanned At",
      "Entrance",
      "Operator",
      "Status",
      "Notes"
    ]

    rows =
      Enum.map(check_ins, fn check_in ->
        attendee_name =
          if check_in.attendee do
            "#{check_in.attendee.first_name || ""} #{check_in.attendee.last_name || ""}"
            |> String.trim()
          else
            ""
          end

        [
          check_in.ticket_code || "",
          attendee_name,
          format_datetime(check_in.checked_in_at),
          check_in.entrance_name || "",
          check_in.operator_name || "",
          check_in.status || "",
          check_in.notes || ""
        ]
      end)

    [headers | rows]
    |> Enum.map(&encode_csv_row/1)
    |> Enum.join("\n")
  end

  defp encode_csv_row(fields) do
    fields
    |> Enum.map(&escape_csv_field/1)
    |> Enum.join(",")
  end

  defp escape_csv_field(field) when is_nil(field), do: ""
  defp escape_csv_field(field) when is_integer(field), do: to_string(field)
  defp escape_csv_field(field) when is_float(field), do: to_string(field)
  defp escape_csv_field(field) when is_boolean(field), do: to_string(field)

  defp escape_csv_field(field) when is_binary(field) do
    # Escape quotes and wrap in quotes if contains comma, newline, or quote
    if String.contains?(field, [",", "\n", "\"", "\r"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end

  defp escape_csv_field(field), do: to_string(field)

  defp format_datetime(nil), do: ""
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(_), do: ""

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 50)
  end

  defp sanitize_filename(_), do: "event"

  defp date_suffix do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d_%H%M%S")
  end
end
