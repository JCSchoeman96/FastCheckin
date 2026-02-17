defmodule FastCheck.Events.Sync do
  @moduledoc """
  Handles synchronization of attendees and event data with Tickera.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Repo
  alias FastCheck.Events.Event
  alias FastCheck.Attendees
  alias FastCheck.TickeraClient
  alias FastCheck.Crypto
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Stats
  alias FastCheck.Events.SyncLog
  alias FastCheck.Events.SyncState

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
      nil ->
        {:error, "Event not found"}

      %Event{} = event ->
        case Events.can_sync_event?(event) do
          {:ok, _state} ->
            mark_syncing(event)

            # Log sync start
            sync_log_id =
              case SyncLog.log_sync_start(event_id) do
                {:ok, log} -> log.id
                {:error, _reason} -> nil
              end

            # Initialize sync state for pause/resume
            SyncState.init_sync(event_id, sync_log_id)

            # Wrap progress callback to include logging and pause checks
            callback =
              wrap_progress_callback_with_pause_check(progress_callback, sync_log_id, event_id)

            case get_tickera_api_key(event) do
              {:ok, api_key} ->
                _ = refresh_event_window_from_tickera(event, api_key)

                case TickeraClient.fetch_all_attendees(
                       event.tickera_site_url,
                       api_key,
                       100,
                       callback
                     ) do
                  {:ok, attendees, total_count} ->
                    Logger.info("Fetched #{total_count} attendees for event #{event.id}")

                    # Filter attendees for incremental sync
                    attendees_to_process =
                      if incremental do
                        filter_incremental_attendees(event.id, attendees, event.last_sync_at)
                      else
                        attendees
                      end

                    case Attendees.create_bulk(event.id, attendees_to_process,
                           incremental: incremental
                         ) do
                      {:ok, processed_count} ->
                        finalize_sync(event)

                        count_message =
                          if incremental do
                            "#{processed_count} new/updated out of #{total_count} total"
                          else
                            resolve_synced_count(processed_count, attendees, total_count)
                          end

                        # Get actual pages processed from sync state BEFORE clearing
                        actual_pages_processed =
                          case SyncState.get_state(event_id) do
                            %{current_page: page} when is_integer(page) and page > 0 -> page
                            # At least 1 page if we got results
                            _ -> 1
                          end

                        # Clear sync state after extracting page count
                        SyncState.clear_state(event_id)

                        # Log successful completion with actual pages processed
                        if sync_log_id do
                          SyncLog.log_sync_completion(
                            sync_log_id,
                            "completed",
                            processed_count,
                            actual_pages_processed
                          )
                        end

                        Cache.invalidate_event_cache(event.id)
                        Cache.invalidate_events_list_cache()
                        Stats.invalidate_event_stats_cache(event.id)
                        Stats.invalidate_occupancy_cache(event.id)
                        stats = Stats.get_event_stats(event.id)
                        Stats.broadcast_event_stats(event.id, stats)

                        sync_message =
                          if incremental,
                            do: "Incremental sync: #{count_message}",
                            else: "Synced #{count_message} attendees"

                        {:ok, sync_message}

                      {:error, reason} ->
                        mark_error(event, reason)
                        SyncState.clear_state(event_id)
                        {:error, format_reason(reason)}
                    end

                  {:error, reason, _partial} ->
                    mark_error(event, reason)
                    SyncState.clear_state(event_id)
                    {:error, format_reason(reason)}
                end

              {:error, :decryption_failed} ->
                mark_error(event, :decryption_failed)
                SyncState.clear_state(event_id)
                {:error, "Unable to decrypt Tickera credentials"}
            end

          {:error, {:event_archived, message}} ->
            Logger.warning("Sync attempt blocked for archived event #{event.id}")
            # No sync state was initialized for blocked syncs
            {:error, message}

          {:error, {_reason, message}} ->
            # No sync state was initialized for blocked syncs
            {:error, message}
        end
    end
  end

  @doc """
  Decrypts the stored Tickera API key for the event.
  """
  @spec get_tickera_api_key(Event.t() | nil) :: {:ok, String.t()} | {:error, :decryption_failed}
  def get_tickera_api_key(%Event{id: id, tickera_api_key_encrypted: encrypted})
      when is_binary(encrypted) do
    case Crypto.decrypt(encrypted) do
      {:ok, api_key} ->
        {:ok, api_key}

      {:error, :decryption_failed} ->
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
    event
    |> Event.changeset(%{status: "error"})
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

  defp filter_incremental_attendees(event_id, attendees, last_sync_at) do
    if is_nil(last_sync_at) do
      # No previous sync, process all
      Logger.info("No previous sync found, processing all #{length(attendees)} attendees")
      attendees
    else
      # Get existing ticket codes for this event
      existing_codes = get_existing_ticket_codes(event_id)

      # Filter to only new tickets
      # In a more sophisticated implementation, we could compare payment_date or other fields
      new_attendees =
        attendees
        |> Enum.filter(fn attendee ->
          ticket_code = Map.get(attendee, :ticket_code) || Map.get(attendee, "checksum")
          ticket_code not in existing_codes
        end)

      Logger.info(
        "Incremental sync: #{length(new_attendees)} new attendees out of #{length(attendees)} total"
      )

      new_attendees
    end
  end

  defp get_existing_ticket_codes(event_id) do
    import Ecto.Query

    FastCheck.Attendees.Attendee
    |> where([a], a.event_id == ^event_id)
    |> select([a], a.ticket_code)
    |> Repo.all(timeout: 15_000)
    |> MapSet.new()
  rescue
    exception ->
      if is_exception(exception) and exception.__struct__ == DBConnection.QueryError do
        Logger.error("Query timeout fetching existing ticket codes for event #{event_id}")
        MapSet.new()
      else
        Logger.error("Database error fetching ticket codes: #{Exception.message(exception)}")
        MapSet.new()
      end
  end

  defp refresh_event_window_from_tickera(%Event{} = event, api_key) do
    case TickeraClient.get_event_essentials(event.tickera_site_url, api_key) do
      {:ok, %{start_date: start_dt, end_date: end_dt}} ->
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
    updates =
      [tickera_start_date: start_dt, tickera_end_date: end_dt]
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

  defp update_sync_timestamp(event_id, updates, _timestamp) do
    from(e in Event, where: e.id == ^event_id)
    |> Repo.update_all(set: updates)
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

  defp same_datetime?(left, right), do: left == right
end
