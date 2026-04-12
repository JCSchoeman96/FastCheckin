defmodule FastCheckWeb.Mobile.SyncController do
  @moduledoc """
  Mobile JSON boundary for FastCheck: sync-down attendee cache plus invalidation feed, sync-up scan batches.

  Mobile scanners use this controller to:
  - Download **active** attendee rows and append-only **invalidation** events under one atomic envelope
  - Upload queued scans when connectivity returns
  """

  use FastCheckWeb, :controller

  action_fallback FastCheckWeb.FallbackController

  require Logger

  import Ecto.Query

  alias FastCheck.Attendees.{Attendee, AttendeeInvalidationEvent}
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Scans.MobileUploadService

  @max_sync_page_size 500

  @doc """
  Returns attendee data for the authenticated event (sync down).

  Invalidations, attendees, and `event_sync_version` are loaded inside one database
  transaction. When `:mobile_sync_snapshot_isolation` is `:repeatable_read` (default
  outside tests), the transaction uses PostgreSQL repeatable-read semantics so those
  reads share one snapshot and are not interleaved with concurrent reconciles.
  """
  def get_attendees(conn, params) do
    event_id = conn.assigns.current_event_id

    with {:ok, since_timestamp} <- parse_since_parameter(params),
         {:ok, since_invalidation_id} <- parse_since_invalidation_id(params),
         {:ok, page_options} <- parse_page_options(params),
         {:ok, snapshot} <-
           fetch_sync_down_snapshot(
             event_id,
             since_timestamp,
             since_invalidation_id,
             page_options
           ) do
      %{
        invalidations: invalidations,
        invalidations_checkpoint: invalidations_checkpoint,
        attendees: attendees,
        next_cursor: next_cursor,
        event_sync_version: event_sync_version
      } = snapshot

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
          invalidations: Enum.map(invalidations, &serialize_invalidation/1),
          count: length(attendees),
          sync_type: sync_type,
          next_cursor: next_cursor,
          invalidations_checkpoint: invalidations_checkpoint,
          event_sync_version: event_sync_version
        },
        error: nil
      })
    else
      {:error, :invalid_since} ->
        bad_request(conn, "invalid_since", "since must be a valid ISO8601 datetime")

      {:error, :invalid_since_invalidation_id} ->
        bad_request(
          conn,
          "invalid_since_invalidation_id",
          "since_invalidation_id must be a non-negative integer"
        )

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

  defp parse_since_invalidation_id(%{"since_invalidation_id" => id_str}) when is_binary(id_str) do
    case Integer.parse(id_str) do
      {parsed, ""} when parsed >= 0 ->
        {:ok, parsed}

      _ ->
        {:error, :invalid_since_invalidation_id}
    end
  end

  defp parse_since_invalidation_id(_params), do: {:ok, 0}

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

  defp fetch_sync_down_snapshot(event_id, since_timestamp, since_invalidation_id, page_options) do
    case Repo.transaction(fn ->
           maybe_set_repeatable_read_for_sync_down!()

           with {:ok, invalidations, invalidations_checkpoint} <-
                  fetch_invalidations(event_id, since_invalidation_id, page_options.limit),
                {:ok, attendees, next_cursor} <-
                  fetch_attendees(
                    event_id,
                    since_timestamp,
                    page_options,
                    page_options.limit
                  ),
                {:ok, event_sync_version} <- fetch_event_sync_version(event_id) do
             %{
               invalidations: invalidations,
               invalidations_checkpoint: invalidations_checkpoint,
               attendees: attendees,
               next_cursor: next_cursor,
               event_sync_version: event_sync_version
             }
           else
             {:error, reason} -> Repo.rollback({:sync_down_query, reason})
           end
         end) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, {:sync_down_query, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_set_repeatable_read_for_sync_down! do
    case Application.get_env(:fastcheck, :mobile_sync_snapshot_isolation, :repeatable_read) do
      :repeatable_read ->
        _ = Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])

      :none ->
        :ok
    end
  end

  defp fetch_invalidations(event_id, since_id, inv_limit)
       when is_integer(event_id) and is_integer(since_id) and is_integer(inv_limit) do
    query =
      from inv in AttendeeInvalidationEvent,
        where: inv.event_id == ^event_id and inv.id > ^since_id,
        order_by: [asc: inv.id],
        limit: ^(inv_limit + 1)

    page_results = Repo.all(query)
    {visible, _overflow} = Enum.split(page_results, inv_limit)

    checkpoint =
      case List.last(visible) do
        %AttendeeInvalidationEvent{id: id} -> id
        nil -> since_id
      end

    {:ok, visible, checkpoint}
  rescue
    error -> {:error, error}
  end

  defp fetch_event_sync_version(event_id) do
    case Repo.one(from(e in Event, where: e.id == ^event_id, select: e.event_sync_version)) do
      v when is_integer(v) -> {:ok, v}
      _ -> {:error, :event_not_found}
    end
  end

  defp fetch_attendees(event_id, since, page_options, att_limit) do
    since = normalize_attendee_timestamp(since)

    query =
      from attendee in Attendee,
        where:
          attendee.event_id == ^event_id and
            (attendee.scan_eligibility == "active" or is_nil(attendee.scan_eligibility)),
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

    limit = att_limit
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

  defp serialize_invalidation(%AttendeeInvalidationEvent{} = inv) do
    %{
      id: inv.id,
      event_id: inv.event_id,
      attendee_id: inv.attendee_id,
      ticket_code: inv.ticket_code,
      change_type: inv.change_type,
      reason_code: inv.reason_code,
      effective_at: serialize_datetime(inv.effective_at),
      source_sync_run_id: format_uuid_for_json(inv.source_sync_run_id)
    }
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

  defp format_uuid_for_json(nil), do: nil

  defp format_uuid_for_json(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, canonical} -> canonical
      :error -> uuid
    end
  end

  defp format_uuid_for_json(_), do: nil

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
