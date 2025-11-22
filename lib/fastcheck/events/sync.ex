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

  @doc """
  Synchronizes attendees for the specified event and updates status timestamps.
  """
  @spec sync_event(integer(), (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def sync_event(event_id, progress_callback \\ nil) do
    Logger.info("Starting attendee sync for event #{event_id}")

    case Repo.get(Event, event_id) do
      nil ->
        {:error, "Event not found"}

      %Event{} = event ->
        case Events.can_sync_event?(event) do
          {:ok, _state} ->
            mark_syncing(event)

            callback = wrap_progress_callback(progress_callback)

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

                    case Attendees.create_bulk(event.id, attendees) do
                      {:ok, inserted_count} ->
                        finalize_sync(event)

                        count_message =
                          resolve_synced_count(inserted_count, attendees, total_count)

                        Cache.invalidate_event_cache(event.id)
                        Cache.invalidate_events_list_cache()
                        Stats.invalidate_event_stats_cache(event.id)
                        Stats.invalidate_occupancy_cache(event.id)
                        stats = Stats.get_event_stats(event.id)
                        Stats.broadcast_event_stats(event.id, stats)
                        {:ok, "Synced #{count_message} attendees"}

                      {:error, reason} ->
                        mark_error(event, reason)
                        {:error, format_reason(reason)}
                    end

                  {:error, reason, _partial} ->
                    mark_error(event, reason)
                    {:error, format_reason(reason)}
                end

              {:error, :decryption_failed} ->
                mark_error(event, :decryption_failed)
                {:error, "Unable to decrypt Tickera credentials"}
            end

          {:error, {:event_archived, message}} ->
            Logger.warning("Sync attempt blocked for archived event #{event.id}")
            {:error, message}

          {:error, {_reason, message}} ->
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

  defp wrap_progress_callback(nil), do: fn _page, _total, _count -> :ok end
  defp wrap_progress_callback(cb) when is_function(cb, 3), do: cb
  defp wrap_progress_callback(_), do: fn _page, _total, _count -> :ok end

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
