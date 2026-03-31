defmodule FastCheckWeb.Mobile.SyncController do
  @moduledoc """
  Handles mobile client data synchronization operations.

  Mobile scanners use this controller to:
  - Download attendee data for offline mode (sync down)
  - Upload queued scans when connectivity returns (sync up)
  """

  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  require Logger

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Scans.MobileUploadService

  @max_sync_page_size 500

  @doc """
  Returns attendee data for the authenticated event (sync down).
  """
  def get_attendees(conn, params) do
    event_id = conn.assigns.current_event_id

    with {:ok, since_timestamp} <- parse_since_parameter(params),
         {:ok, page_options} <- parse_page_options(params),
         {:ok, attendees, next_cursor} <- fetch_attendees(event_id, since_timestamp, page_options) do
      server_time = DateTime.utc_now() |> DateTime.truncate(:second)
      sync_type = if since_timestamp, do: "incremental", else: "full"

      Logger.info("Mobile sync down completed",
        event_id: event_id,
        sync_type: sync_type,
        count: length(attendees),
        cursor: page_options.cursor,
        page_limit: page_options.limit,
        next_cursor: next_cursor,
        since: since_timestamp,
        ip: get_peer_ip(conn)
      )

      json(conn, %{
        data: %{
          server_time: DateTime.to_iso8601(server_time),
          attendees: Enum.map(attendees, &serialize_attendee/1),
          count: length(attendees),
          sync_type: sync_type,
          next_cursor: next_cursor
        },
        error: nil
      })
    else
      {:error, :invalid_since} ->
        bad_request(conn, "invalid_since", "since must be a valid ISO8601 datetime")

      {:error, :missing_limit} ->
        bad_request(conn, "missing_limit", "Parameter 'limit' is required")

      {:error, :invalid_limit} ->
        bad_request(conn, "invalid_limit", "Parameter 'limit' must be a positive integer")

      {:error, :limit_too_large} ->
        bad_request(
          conn,
          "limit_too_large",
          "Parameter 'limit' must be <= #{@max_sync_page_size}"
        )

      {:error, :invalid_cursor} ->
        bad_request(conn, "invalid_cursor", "Parameter 'cursor' is invalid")

      {:error, reason} ->
        Logger.error("Mobile sync down failed",
          event_id: event_id,
          reason: inspect(reason),
          ip: get_peer_ip(conn)
        )

        server_error(conn, "sync_failed", "Unable to retrieve attendee data")
    end
  end

  @doc """
  Accepts a batch of scanned check-ins from mobile clients (sync up).
  """
  def upload_scans(conn, %{"scans" => scans}) when is_list(scans) do
    event_id = conn.assigns.current_event_id
    started_at = System.monotonic_time(:millisecond)

    Logger.info("Mobile scan upload started",
      event_id: event_id,
      scan_count: length(scans),
      ip: get_peer_ip(conn)
    )

    case MobileUploadService.upload_batch(event_id, scans) do
      {:ok, results} ->
        success_count = Enum.count(results, &(&1.status == "success"))
        duplicate_count = Enum.count(results, &(&1.status == "duplicate"))
        error_count = Enum.count(results, &(&1.status == "error"))
        duration_ms = System.monotonic_time(:millisecond) - started_at

        emit_mobile_sync_batch_telemetry(
          event_id,
          length(results),
          success_count,
          duplicate_count,
          error_count,
          duration_ms
        )

        Logger.info("Mobile scan upload completed",
          event_id: event_id,
          total: length(results),
          success: success_count,
          duplicate: duplicate_count,
          error: error_count,
          duration_ms: duration_ms,
          ip: get_peer_ip(conn)
        )

        json(conn, %{data: %{results: results, processed: length(results)}, error: nil})

      {:error, %{status: status, code: code, message: message}} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        Logger.error("Mobile scan upload failed",
          event_id: event_id,
          code: code,
          duration_ms: duration_ms,
          ip: get_peer_ip(conn)
        )

        conn
        |> put_status(status)
        |> json(%{data: nil, error: %{code: code, message: message}})
    end
  end

  def upload_scans(conn, _params) do
    bad_request(conn, "invalid_request", "Request body must contain 'scans' array")
  end

  defp emit_mobile_sync_batch_telemetry(
         event_id,
         total,
         success_count,
         duplicate_count,
         error_count,
         duration_ms
       ) do
    :telemetry.execute(
      [:fastcheck, :mobile_sync, :batch, :duration],
      %{duration_ms: duration_ms},
      %{
        event_id: event_id,
        total: total,
        success: success_count,
        duplicate: duplicate_count,
        error: error_count
      }
    )
  rescue
    _ -> :ok
  end

  defp bad_request(conn, error_code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      data: nil,
      error: %{
        code: error_code,
        message: message
      }
    })
  end

  defp parse_since_parameter(%{"since" => since_str}) when is_binary(since_str) do
    case DateTime.from_iso8601(since_str) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      {:error, _reason} ->
        Logger.warning("Invalid 'since' parameter", since: since_str)
        {:error, :invalid_since}
    end
  end

  defp parse_since_parameter(_params), do: {:ok, nil}

  defp parse_page_options(params) do
    with {:ok, limit} <- parse_limit_parameter(params),
         {:ok, cursor} <- parse_cursor_parameter(params) do
      {:ok, %{limit: limit, cursor: cursor}}
    end
  end

  defp parse_limit_parameter(%{"limit" => limit}) do
    case Integer.parse(limit) do
      {parsed_limit, ""} when parsed_limit > 0 and parsed_limit <= @max_sync_page_size ->
        {:ok, parsed_limit}

      {parsed_limit, ""} when parsed_limit > @max_sync_page_size ->
        {:error, :limit_too_large}

      _ ->
        {:error, :invalid_limit}
    end
  end

  defp parse_limit_parameter(_params), do: {:error, :missing_limit}

  defp parse_cursor_parameter(%{"cursor" => cursor}) when is_binary(cursor) do
    case decode_cursor(cursor) do
      {:ok, _decoded} = ok -> ok
      :error -> {:error, :invalid_cursor}
    end
  end

  defp parse_cursor_parameter(_params), do: {:ok, nil}

  defp fetch_attendees(event_id, since, page_options) do
    since = normalize_attendee_timestamp(since)

    query =
      from attendee in Attendee,
        where: attendee.event_id == ^event_id,
        order_by: [asc: attendee.updated_at, asc: attendee.id]

    query =
      if since do
        from attendee in query, where: attendee.updated_at > ^since
      else
        query
      end

    query =
      case page_options.cursor do
        {cursor_updated_at, cursor_id} ->
          from attendee in query,
            where:
              attendee.updated_at > ^cursor_updated_at or
                (attendee.updated_at == ^cursor_updated_at and attendee.id > ^cursor_id)

        nil ->
          query
      end

    limit = page_options.limit
    page_results = Repo.all(from attendee in query, limit: ^(limit + 1))
    {visible_results, overflow_results} = Enum.split(page_results, limit)

    next_cursor =
      case overflow_results do
        [] -> nil
        [_ | _] -> encode_cursor(List.last(visible_results))
      end

    {:ok, visible_results, next_cursor}
  rescue
    error ->
      {:error, error}
  end

  defp decode_cursor(encoded_cursor) do
    with {:ok, decoded} <- Base.url_decode64(encoded_cursor, padding: false),
         [updated_at_iso8601, id_str] <- String.split(decoded, "|", parts: 2),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(updated_at_iso8601),
         {id, ""} <- Integer.parse(id_str) do
      {:ok, {DateTime.to_naive(updated_at), id}}
    else
      _ -> :error
    end
  end

  defp encode_cursor(attendee) do
    cursor =
      [
        serialize_datetime(attendee.updated_at),
        attendee.id
      ]
      |> Enum.join("|")

    Base.url_encode64(cursor, padding: false)
  end

  defp serialize_attendee(attendee) do
    %{
      id: attendee.id,
      event_id: attendee.event_id,
      ticket_code: attendee.ticket_code,
      first_name: attendee.first_name,
      last_name: attendee.last_name,
      email: attendee.email,
      ticket_type: attendee.ticket_type,
      allowed_checkins: attendee.allowed_checkins || 1,
      checkins_remaining: attendee.checkins_remaining || attendee.allowed_checkins || 1,
      payment_status: attendee.payment_status,
      is_currently_inside: attendee.is_currently_inside || false,
      checked_in_at: serialize_datetime(attendee.checked_in_at),
      checked_out_at: serialize_datetime(attendee.checked_out_at),
      updated_at: serialize_datetime(attendee.updated_at)
    }
  end

  defp serialize_datetime(nil), do: nil
  defp serialize_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp serialize_datetime(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp serialize_datetime(_), do: nil

  defp normalize_attendee_timestamp(nil), do: nil
  defp normalize_attendee_timestamp(%DateTime{} = datetime), do: DateTime.to_naive(datetime)

  defp get_peer_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        ip |> String.split(",") |> List.first() |> String.trim()

      _ ->
        %{address: address} = Plug.Conn.get_peer_data(conn)
        :inet.ntoa(address) |> to_string()
    end
  end

  defp server_error(conn, error_code, message) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      data: nil,
      error: %{
        code: error_code,
        message: message
      }
    })
  end
end
