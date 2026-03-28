defmodule FastCheck.Events.Sync do
  @moduledoc """
  Handles synchronization of attendees and event data with Tickera.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Attendees
  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Events.Stats
  alias FastCheck.Events.SyncLog
  alias FastCheck.Events.SyncState
  alias FastCheck.Repo
  alias FastCheck.TickeraClient

  @doc """
  Synchronizes attendees for the specified event and updates status timestamps.

  Options:
  - `:incremental` - If true, only syncs new/updated attendees since last sync (default: false)
  """
  @spec sync_event(
          integer(),
          (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil,
          keyword()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  def sync_event(event_id, progress_callback \\ nil, opts \\ []) do
    incremental = Keyword.get(opts, :incremental, false)
    sync_type = if incremental, do: "incremental", else: "full"
    Logger.info("Starting #{sync_type} attendee sync for event #{event_id}")

    case Repo.get(Event, event_id) do
      nil -> {:error, "Event not found"}
      %Event{} = event -> sync_loaded_event(event, progress_callback, incremental)
    end
  end

  defp sync_loaded_event(event, progress_callback, incremental) do
    case Events.can_sync_event?(event) do
      {:ok, _state} ->
        run_event_sync(event, progress_callback, incremental)

      {:error, {:event_archived, message}} ->
        Logger.warning("Sync attempt blocked for archived event #{event.id}")
        {:error, message}

      {:error, {_reason, message}} ->
        {:error, message}
    end
  end

  defp run_event_sync(event, progress_callback, incremental) do
    mark_syncing(event)
    sync_log_id = log_sync_start_id(event.id)
    SyncState.init_sync(event.id, sync_log_id)

    callback =
      wrap_progress_callback_with_pause_check(progress_callback, sync_log_id, event.id)

    case get_tickera_api_key(event) do
      {:ok, api_key} ->
        sync_event_with_api_key(event, api_key, callback, incremental, sync_log_id)

      {:error, :decryption_failed} ->
        fail_sync(event, sync_log_id, :decryption_failed, "Unable to decrypt Tickera credentials")
    end
  end

  defp sync_event_with_api_key(event, api_key, callback, incremental, sync_log_id) do
    _ = refresh_event_window_from_tickera(event, api_key)

    case TickeraClient.fetch_all_attendees(event.tickera_site_url, api_key, 50, callback) do
      {:ok, attendees, total_count} ->
        process_fetched_attendees(event, attendees, total_count, incremental, sync_log_id)

      {:error, reason, _partial} ->
        fail_sync(event, sync_log_id, reason, format_reason(reason))
    end
  end

  defp process_fetched_attendees(event, attendees, total_count, incremental, sync_log_id) do
    Logger.info("Fetched #{total_count} attendees for event #{event.id}")

    attendees_to_process = attendees_for_sync(event, attendees, incremental)

    case Attendees.create_bulk(event.id, attendees_to_process, incremental: incremental) do
      {:ok, processed_count} ->
        complete_sync(event, attendees, total_count, processed_count, incremental, sync_log_id)

      {:error, reason} ->
        fail_sync(event, sync_log_id, reason, format_reason(reason))
    end
  end

  defp attendees_for_sync(event, attendees, true) do
    incremental_attendees_for_sync(event.id, attendees, event.last_sync_at)
  end

  defp attendees_for_sync(_event, attendees, false), do: attendees

  defp complete_sync(event, attendees, total_count, processed_count, incremental, sync_log_id) do
    finalize_sync(event)

    count_message =
      build_sync_count_message(incremental, processed_count, attendees, total_count)

    actual_pages_processed = current_sync_pages(event.id)
    SyncState.clear_state(event.id)
    maybe_log_sync_completion(sync_log_id, processed_count, actual_pages_processed)
    invalidate_sync_caches(event.id)

    sync_message =
      if incremental,
        do: "Incremental sync: #{count_message}",
        else: "Synced #{count_message} attendees"

    {:ok, sync_message}
  end

  defp build_sync_count_message(true, processed_count, _attendees, total_count) do
    "#{processed_count} new/updated out of #{total_count} total"
  end

  defp build_sync_count_message(false, processed_count, attendees, total_count) do
    resolve_synced_count(processed_count, attendees, total_count)
  end

  defp current_sync_pages(event_id) do
    case SyncState.get_state(event_id) do
      %{current_page: page} when is_integer(page) and page > 0 -> page
      _ -> 1
    end
  end

  defp maybe_log_sync_completion(nil, _processed_count, _actual_pages_processed), do: :ok

  defp maybe_log_sync_completion(sync_log_id, processed_count, actual_pages_processed) do
    SyncLog.log_sync_completion(sync_log_id, "completed", processed_count, actual_pages_processed)
  end

  defp invalidate_sync_caches(event_id) do
    Cache.invalidate_event_cache(event_id)
    Cache.invalidate_events_list_cache()
    Stats.invalidate_event_stats_cache(event_id)
    Stats.invalidate_occupancy_cache(event_id)
    stats = Stats.get_event_stats(event_id)
    Stats.broadcast_event_stats(event_id, stats)
  end

  defp fail_sync(event, sync_log_id, reason, message) do
    log_sync_failure(sync_log_id, event.id, reason)
    mark_error(event, reason)
    SyncState.clear_state(event.id)
    {:error, message}
  end

  defp log_sync_start_id(event_id) do
    case SyncLog.log_sync_start(event_id) do
      {:ok, log} -> log.id
      {:error, _reason} -> nil
    end
  end

  @doc """
  Decrypts the stored Tickera API key for the event.
  """
  @spec get_tickera_api_key(Event.t() | nil) :: {:ok, String.t()} | {:error, :decryption_failed}
  def get_tickera_api_key(%Event{id: id, tickera_api_key_encrypted: encrypted})
      when is_binary(encrypted) do
    case Crypto.decrypt(encrypted) do
      {:ok, api_key} when is_binary(api_key) ->
        case String.trim(api_key) do
          "" ->
            Logger.warning("Tickera API key is empty after normalization for event #{id}")
            {:error, :decryption_failed}

          normalized ->
            {:ok, normalized}
        end

      {:ok, _unexpected} ->
        Logger.warning("Tickera API key decrypted to a non-binary value for event #{id}")
        {:error, :decryption_failed}

      {:error, :decryption_failed} ->
        Logger.warning("Unable to decrypt Tickera API key for event #{id}")
        {:error, :decryption_failed}

      {:error, _reason} ->
        Logger.warning("Unable to decrypt Tickera API key for event #{id}")
        {:error, :decryption_failed}
    end
  end

  def get_tickera_api_key(%Event{id: id}) do
    Logger.warning("Event #{id} is missing encrypted Tickera credentials")
    {:error, :decryption_failed}
  end

  def get_tickera_api_key(_), do: {:error, :decryption_failed}

  @doc """
  Updates `last_sync_at` to the current timestamp for the event.
  """
  @spec touch_last_sync(integer()) :: :ok | {:error, term()}
  def touch_last_sync(event_id) when is_integer(event_id) and event_id > 0 do
    timestamp = current_timestamp()
    update_sync_timestamp(event_id, %{last_sync_at: timestamp}, timestamp)
  end

  def touch_last_sync(_), do: {:error, :invalid_event}

  @doc """
  Updates `last_soft_sync_at` to the current timestamp for the event.
  """
  @spec touch_last_soft_sync(integer()) :: :ok | {:error, term()}
  def touch_last_soft_sync(event_id) when is_integer(event_id) and event_id > 0 do
    timestamp = current_timestamp()
    update_sync_timestamp(event_id, %{last_soft_sync_at: timestamp}, timestamp)
  end

  def touch_last_soft_sync(_), do: {:error, :invalid_event}

  @doc """
  Force-resets sync runtime state for an event.

  This is used by external workers (for example LiveView background sync tasks)
  when a sync attempt is terminated early due to timeout, cancellation, or crash.
  """
  @spec force_reset_sync(integer(), term()) :: :ok
  def force_reset_sync(event_id, reason \\ :unspecified)

  def force_reset_sync(event_id, reason) when is_integer(event_id) and event_id > 0 do
    SyncState.clear_state(event_id)

    case Repo.get(Event, event_id) do
      %Event{} = event ->
        if syncing_status?(event) do
          now = current_timestamp()

          event
          |> Event.changeset(%{status: "active", last_soft_sync_at: now})
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              Cache.invalidate_event_cache(updated.id)
              Cache.invalidate_events_list_cache()
              :ok

            {:error, update_reason} ->
              Logger.warning(
                "Failed to force-reset sync state for event #{event_id}: #{inspect(update_reason)}"
              )

              :ok
          end
        else
          :ok
        end

      _ ->
        :ok
    end

    Logger.warning("Force reset sync runtime for event #{event_id}: #{inspect(reason)}")
    :ok
  end

  def force_reset_sync(_event_id, _reason), do: :ok

  # Private Helpers

  defp mark_syncing(%Event{} = event) do
    event
    |> Event.changeset(%{status: "syncing"})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cache.invalidate_event_cache(updated.id)
        Cache.invalidate_events_list_cache()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark event #{event.id} as syncing: #{inspect(reason)}")
        :ok
    end
  end

  defp finalize_sync(%Event{} = event) do
    now = current_timestamp()

    event
    |> Event.changeset(%{
      status: "active",
      last_sync_at: now,
      last_soft_sync_at: now
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cache.invalidate_event_cache(updated.id)
        Cache.invalidate_events_list_cache()
        :ok

      {:error, reason} ->
        Logger.warning("Failed to finalize sync for event #{event.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_error(%Event{} = event, reason) do
    now = current_timestamp()

    event
    |> Event.changeset(%{status: "active", last_soft_sync_at: now})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        Cache.invalidate_event_cache(updated.id)
        Cache.invalidate_events_list_cache()
        Logger.error("Sync failed for event #{event.id}: #{inspect(reason)}")
        :ok

      {:error, update_reason} ->
        Logger.error(
          "Failed to mark error status for event #{event.id}: #{inspect(update_reason)}"
        )

        :ok
    end
  end

  defp log_sync_failure(nil, _event_id, _reason), do: :ok

  defp log_sync_failure(sync_log_id, event_id, reason) do
    pages_processed =
      case SyncState.get_state(event_id) do
        %{current_page: page} when is_integer(page) and page > 0 -> page
        _ -> 0
      end

    _ = SyncLog.log_sync_error(sync_log_id, format_reason(reason), pages_processed)
    :ok
  rescue
    exception ->
      Logger.warning("Failed to persist sync failure log: #{Exception.message(exception)}")
      :ok
  end

  defp resolve_synced_count(inserted, _attendees, total) when inserted == total, do: "#{total}"
  defp resolve_synced_count(inserted, _attendees, total), do: "#{inserted}/#{total}"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp wrap_progress_callback_with_pause_check(nil, sync_log_id, event_id) do
    fn page, total, count ->
      # Update sync state
      SyncState.update_progress(event_id, page, total, count)

      # Update sync log
      if sync_log_id do
        SyncLog.update_progress(sync_log_id, page, count)
      end

      # Check if paused - wait until resumed or cancelled
      wait_if_paused(event_id)

      :ok
    end
  end

  defp wrap_progress_callback_with_pause_check(cb, sync_log_id, event_id)
       when is_function(cb, 3) do
    fn page, total, count ->
      # Update sync state
      SyncState.update_progress(event_id, page, total, count)

      # Update sync log
      if sync_log_id do
        SyncLog.update_progress(sync_log_id, page, count)
      end

      # Call original callback
      cb.(page, total, count)

      # Check if paused - wait until resumed or cancelled
      wait_if_paused(event_id)

      :ok
    end
  end

  defp wrap_progress_callback_with_pause_check(_, sync_log_id, event_id) do
    fn page, total, count ->
      # Update sync state
      SyncState.update_progress(event_id, page, total, count)

      # Update sync log
      if sync_log_id do
        SyncLog.update_progress(sync_log_id, page, count)
      end

      # Check if paused - wait until resumed or cancelled
      wait_if_paused(event_id)

      :ok
    end
  end

  defp wait_if_paused(event_id) do
    case SyncState.get_state(event_id) do
      %{status: :paused} ->
        # Wait in a loop until resumed or cancelled
        wait_for_resume(event_id)

      %{status: :cancelled} ->
        # Throw to stop sync
        throw({:sync_cancelled, event_id})

      _ ->
        # Running, continue
        :ok
    end
  end

  defp wait_for_resume(event_id) do
    case SyncState.get_state(event_id) do
      %{status: :running} ->
        :ok

      %{status: :cancelled} ->
        throw({:sync_cancelled, event_id})

      _ ->
        # Still paused, wait a bit and check again
        Process.sleep(500)
        wait_for_resume(event_id)
    end
  end

  @doc """
  Selects attendees to process during incremental sync.

  This is intentionally public to keep selection behavior directly testable and
  stable for callers that may need the same "new-or-changed" policy.

  Selection policy:
  - include attendees with ticket codes not found locally
  - include attendees where sync-relevant fields changed (`first_name`,
    `last_name`, `email`, `payment_status`, `ticket_type`, `allowed_checkins`)
  """
  @spec incremental_attendees_for_sync(integer(), list(map()), DateTime.t() | nil) :: list(map())
  def incremental_attendees_for_sync(event_id, attendees, last_sync_at) do
    if is_nil(last_sync_at) do
      # No previous sync, process all
      Logger.info("No previous sync found, processing all #{length(attendees)} attendees")
      attendees
    else
      existing_attendees_by_code = get_existing_incremental_sync_fields(event_id)

      new_attendees =
        Enum.filter(attendees, fn attendee ->
          case attendee_ticket_code(attendee) do
            nil ->
              false

            ticket_code ->
              remote_fields = attendee_incremental_sync_fields(attendee)

              case Map.get(existing_attendees_by_code, ticket_code) do
                nil -> true
                existing_fields -> existing_fields != remote_fields
              end
          end
        end)

      Logger.info(
        "Incremental sync: #{length(new_attendees)} new/updated attendees out of #{length(attendees)} total"
      )

      new_attendees
    end
  end

  defp attendee_ticket_code(attendee) do
    Map.get(attendee, :ticket_code) ||
      Map.get(attendee, "ticket_code") ||
      Map.get(attendee, "checksum")
  end

  defp attendee_incremental_sync_fields(attendee) do
    parsed = TickeraClient.parse_attendee(attendee)

    %{
      first_name: Map.get(parsed, :first_name),
      last_name: Map.get(parsed, :last_name),
      email: Map.get(parsed, :email),
      payment_status: Map.get(parsed, :payment_status),
      ticket_type: Map.get(parsed, :ticket_type),
      allowed_checkins: Attendees.normalize_allowed_checkins(Map.get(parsed, :allowed_checkins))
    }
  end

  defp get_existing_incremental_sync_fields(event_id) do
    import Ecto.Query

    FastCheck.Attendees.Attendee
    |> where([a], a.event_id == ^event_id)
    |> select([a], %{
      ticket_code: a.ticket_code,
      first_name: a.first_name,
      last_name: a.last_name,
      email: a.email,
      payment_status: a.payment_status,
      ticket_type: a.ticket_type,
      allowed_checkins: a.allowed_checkins
    })
    |> Repo.all(timeout: 15_000)
    |> Map.new(fn attendee ->
      {attendee.ticket_code,
       %{
         first_name: attendee.first_name,
         last_name: attendee.last_name,
         email: attendee.email,
         payment_status: attendee.payment_status,
         ticket_type: attendee.ticket_type,
         allowed_checkins: Attendees.normalize_allowed_checkins(attendee.allowed_checkins)
       }}
    end)
  rescue
    exception ->
      if is_exception(exception) and exception.__struct__ == DBConnection.QueryError do
        Logger.warning(
          "Query timeout fetching existing attendees for event #{event_id}; " <>
            "falling back to include all remote attendees in incremental sync"
        )

        %{}
      else
        Logger.warning(
          "Database error fetching existing attendees for event #{event_id}; " <>
            "falling back to include all remote attendees in incremental sync: " <>
            Exception.message(exception)
        )

        %{}
      end
  end

  defp refresh_event_window_from_tickera(%Event{} = event, api_key) do
    case TickeraClient.get_event_essentials(event.tickera_site_url, api_key) do
      {:ok, essentials} when is_map(essentials) ->
        start_dt =
          Map.get(essentials, "event_start_date") ||
            Map.get(essentials, :event_start_date) ||
            Map.get(essentials, "event_date_time") ||
            Map.get(essentials, :event_date_time)

        end_dt =
          Map.get(essentials, "event_end_date") ||
            Map.get(essentials, :event_end_date)

        persist_event_window(event, start_dt, end_dt)

      {:error, :decryption_failed} ->
        Logger.warning("Unable to decrypt credentials for window refresh event #{event.id}")
        :error

      {:error, reason} ->
        Logger.debug(fn ->
          {"event window refresh skipped", event_id: event.id, reason: inspect(reason)}
        end)

        :error
    end
  end

  defp persist_event_window(_event, nil, nil), do: :unchanged

  defp persist_event_window(%Event{} = event, start_dt, end_dt) do
    normalized_start = coerce_window_datetime(start_dt)
    normalized_end = coerce_window_datetime(end_dt)

    updates =
      [tickera_start_date: normalized_start, tickera_end_date: normalized_end]
      |> Enum.reduce(%{}, fn
        {_field, nil}, acc ->
          acc

        {field, value}, acc ->
          current = Map.get(event, field)

          if same_datetime?(current, value) do
            acc
          else
            Map.put(acc, field, value)
          end
      end)

    if map_size(updates) == 0 do
      :unchanged
    else
      event
      |> Changeset.change(updates)
      |> Repo.update()
      |> case do
        {:ok, %Event{} = updated} ->
          Cache.invalidate_event_cache(updated.id)
          Cache.invalidate_events_list_cache()
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp coerce_window_datetime(nil), do: nil

  defp coerce_window_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone("Etc/UTC")
    |> case do
      {:ok, shifted} -> DateTime.truncate(shifted, :second)
      {:error, _reason} -> DateTime.truncate(datetime, :second)
    end
  end

  defp coerce_window_datetime(%NaiveDateTime{} = datetime) do
    case DateTime.from_naive(datetime, "Etc/UTC") do
      {:ok, utc} -> DateTime.truncate(utc, :second)
      _ -> nil
    end
  end

  defp coerce_window_datetime(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_window_datetime(%Time{} = time) do
    DateTime.new(Date.utc_today(), time, "Etc/UTC")
    |> case do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_window_datetime(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_window_datetime(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        parse_window_datetime_string(trimmed)
    end
  end

  defp coerce_window_datetime(_value), do: nil

  defp parse_window_datetime_string(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        coerce_window_datetime(datetime)

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} ->
            coerce_window_datetime(naive)

          {:error, _reason} ->
            case Integer.parse(value) do
              {unix, ""} ->
                coerce_window_datetime(unix)

              _ ->
                parse_window_datetime_human(value)
            end
        end
    end
  end

  defp parse_window_datetime_human(value) when is_binary(value) do
    regexes = [
      ~r/^(?<month>[[:alpha:].]+)\s+(?<day>\d{1,2})(?:st|nd|rd|th)?[,]?\s+(?<year>\d{4})\s+(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<meridian>[[:alpha:]]+)?$/iu,
      ~r/^(?<day>\d{1,2})(?:st|nd|rd|th)?\s+(?<month>[[:alpha:].]+)\s+(?<year>\d{4})\s+(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?<meridian>[[:alpha:]]+)?$/iu
    ]

    Enum.find_value(regexes, fn regex ->
      case Regex.named_captures(regex, value) do
        nil -> nil
        captures -> build_datetime_from_human_parts(captures)
      end
    end)
  end

  defp parse_window_datetime_human(_value), do: nil

  defp build_datetime_from_human_parts(parts) when is_map(parts) do
    with {:ok, year} <- parse_int(Map.get(parts, "year")),
         {:ok, month} <- parse_month(Map.get(parts, "month")),
         {:ok, day} <- parse_int(Map.get(parts, "day")),
         {:ok, hour} <- parse_int(Map.get(parts, "hour")),
         {:ok, minute} <- parse_int(Map.get(parts, "minute")),
         {:ok, adjusted_hour} <- adjust_hour(hour, Map.get(parts, "meridian")),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(adjusted_hour, minute, 0),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      DateTime.truncate(datetime, :second)
    else
      _ -> nil
    end
  end

  defp build_datetime_from_human_parts(_parts), do: nil

  defp parse_month(nil), do: :error

  defp parse_month(month_name) when is_binary(month_name) do
    normalized =
      month_name
      |> String.trim()
      |> String.downcase()
      |> String.replace(".", "")

    month =
      %{
        "january" => 1,
        "januarie" => 1,
        "jan" => 1,
        "february" => 2,
        "februarie" => 2,
        "feb" => 2,
        "march" => 3,
        "maart" => 3,
        "mar" => 3,
        "april" => 4,
        "apr" => 4,
        "may" => 5,
        "mei" => 5,
        "jun" => 6,
        "june" => 6,
        "junie" => 6,
        "jul" => 7,
        "july" => 7,
        "julie" => 7,
        "aug" => 8,
        "august" => 8,
        "augustus" => 8,
        "sep" => 9,
        "sept" => 9,
        "september" => 9,
        "oct" => 10,
        "okt" => 10,
        "october" => 10,
        "oktober" => 10,
        "nov" => 11,
        "november" => 11,
        "dec" => 12,
        "december" => 12,
        "desember" => 12
      }
      |> Map.get(normalized)

    case month do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp parse_month(_month_name), do: :error

  defp parse_int(nil), do: :error

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_int(value) when is_integer(value), do: {:ok, value}
  defp parse_int(_value), do: :error

  defp adjust_hour(hour, meridian) when is_integer(hour) and hour >= 0 and hour <= 23 do
    case normalize_meridian(meridian) do
      :am -> {:ok, normalize_am_hour(hour)}
      :pm -> {:ok, normalize_pm_hour(hour)}
      _ -> {:ok, hour}
    end
  end

  defp adjust_hour(_hour, _meridian), do: :error

  defp normalize_meridian(meridian) do
    case meridian |> to_string() |> String.trim() |> String.downcase() do
      meridian when meridian in ["am", "vm"] -> :am
      meridian when meridian in ["pm", "nm"] -> :pm
      _ -> :none
    end
  end

  defp normalize_am_hour(12), do: 0
  defp normalize_am_hour(hour), do: hour

  defp normalize_pm_hour(hour) when hour < 12, do: hour + 12
  defp normalize_pm_hour(hour), do: hour

  defp update_sync_timestamp(event_id, updates, _timestamp) do
    from(e in Event, where: e.id == ^event_id)
    |> Repo.update_all(set: Map.to_list(updates))
    |> case do
      {1, _} ->
        Cache.invalidate_event_cache(event_id)
        Cache.invalidate_events_list_cache()
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp current_timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp syncing_status?(%Event{status: status}) when is_binary(status) do
    String.downcase(String.trim(status)) == "syncing"
  end

  defp syncing_status?(_), do: false

  defp same_datetime?(nil, nil), do: true
  defp same_datetime?(nil, _other), do: false
  defp same_datetime?(_other, nil), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(DateTime.truncate(left, :second), DateTime.truncate(right, :second)) == :eq
  end

  defp same_datetime?(%NaiveDateTime{} = left, %NaiveDateTime{} = right) do
    NaiveDateTime.compare(
      NaiveDateTime.truncate(left, :second),
      NaiveDateTime.truncate(right, :second)
    ) == :eq
  end

  defp same_datetime?(%DateTime{} = left, %NaiveDateTime{} = right) do
    case DateTime.from_naive(right, "Etc/UTC") do
      {:ok, right_dt} -> same_datetime?(left, right_dt)
      _ -> false
    end
  end

  defp same_datetime?(%NaiveDateTime{} = left, %DateTime{} = right) do
    case DateTime.from_naive(left, "Etc/UTC") do
      {:ok, left_dt} -> same_datetime?(left_dt, right)
      _ -> false
    end
  end

  defp same_datetime?(left, right), do: left == right
end
