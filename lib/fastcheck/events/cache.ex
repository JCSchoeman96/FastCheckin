defmodule FastCheck.Events.Cache do
  @moduledoc """
  Handles caching for events and event lists.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Repo
  alias FastCheck.Events.Event
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer

  @event_config_ttl :timer.hours(1)
  @events_list_ttl :timer.minutes(15)
  @events_list_cache_key "events:all"

  @doc """
  Retrieves an event by id using a cache-aside strategy.
  """
  @spec get_event!(integer()) :: Event.t()
  def get_event!(event_id) when is_integer(event_id) and event_id > 0 do
    case EtsLayer.get_event_config(event_id) do
      {:ok, %Event{} = event} ->
        event

      {:ok, _other} ->
        cache_fallback(event_id)

      :not_found ->
        cache_fallback(event_id)
    end
  end

  def get_event!(event_id), do: Repo.get!(Event, event_id)

  @doc """
  Lists cached events along with their attendee counts, falling back to the
  database when the cache is cold.
  """
  @spec list_events() :: [Event.t()]
  def list_events do
    case CacheManager.get(@events_list_cache_key) do
      {:ok, events} when is_list(events) ->
        # Verify list contains only Events
        events =
          Enum.filter(events, fn
            %Event{} -> true
            _ -> false
          end)

        events

      {:ok, nil} ->
        Logger.debug(fn -> {"events cache miss", key: @events_list_cache_key} end)
        fetch_and_cache_events()

      {:ok, other} ->
        Logger.debug(fn ->
          {"events cache miss due to unexpected payload", payload: inspect(other)}
        end)

        fetch_and_cache_events()

      {:error, reason} ->
        Logger.warning(fn -> {"events cache unavailable", reason: inspect(reason)} end)
        fetch_events_from_db()
    end
  end

  def invalidate_event_cache(event_id) do
    EtsLayer.invalidate_event_config(event_id)

    case CacheManager.delete(event_config_cache_key(event_id)) do
      {:ok, _} ->
        Logger.debug(fn -> {"event cache invalidated", event_id: event_id} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"event cache invalidate failed", event_id: event_id, reason: inspect(reason)}
        end)

        :error
    end
  end

  def invalidate_events_list_cache do
    case CacheManager.delete(@events_list_cache_key) do
      {:ok, _} ->
        Logger.debug(fn -> {"events list cache invalidated", key: @events_list_cache_key} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"events list cache invalidate failed", reason: inspect(reason)}
        end)

        :error
    end
  end

  def persist_event_cache(%Event{} = event) do
    case CacheManager.put(event_config_cache_key(event.id), event, ttl: @event_config_ttl) do
      {:ok, true} ->
        EtsLayer.put_event_config(event.id, event)
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"event cache write failed", event_id: event.id, reason: inspect(reason)}
        end)

        :error
    end
  end

  # Private Helpers

  defp cache_fallback(event_id) do
    case CacheManager.get(event_config_cache_key(event_id)) do
      {:ok, %Event{} = event} ->
        EtsLayer.put_event_config(event_id, event)
        event

      {:ok, nil} ->
        Logger.debug(fn -> {"event cache miss", event_id: event_id} end)
        fetch_and_cache_event!(event_id)

      {:ok, other} ->
        Logger.debug(fn ->
          {"event cache miss due to unexpected payload", payload: inspect(other)}
        end)

        fetch_and_cache_event!(event_id)

      {:error, reason} ->
        Logger.warning(fn ->
          {"event cache unavailable", event_id: event_id, reason: inspect(reason)}
        end)

        Repo.get!(Event, event_id)
    end
  end

  defp fetch_and_cache_event!(event_id) do
    event = Repo.get!(Event, event_id)
    _ = persist_event_cache(event)
    event
  end

  defp fetch_and_cache_events do
    events = fetch_events_from_db()
    cache_events_list(events)
    events
  end

  defp fetch_events_from_db do
    # Optimized query: Use subquery for attendee counts to avoid N+1
    # This is more efficient than a left join with group_by
    attendee_counts =
      from(a in Attendee,
        group_by: a.event_id,
        select: %{event_id: a.event_id, attendee_count: count(a.id)}
      )
      |> Repo.all()
      |> Map.new(fn %{event_id: id, attendee_count: count} -> {id, count} end)

    # Fetch events and merge attendee counts
    events =
      Event
      |> order_by([e], [desc: e.inserted_at])
      |> Repo.all(timeout: 10_000)

    # Merge attendee counts into events
    Enum.map(events, fn event ->
      attendee_count = Map.get(attendee_counts, event.id, 0)
      %{event | attendee_count: attendee_count}
    end)
  end

  defp cache_events_list(events) do
    case CacheManager.put(@events_list_cache_key, events, ttl: @events_list_ttl) do
      {:ok, true} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"events list cache write failed", reason: inspect(reason)}
        end)

        :error
    end
  end

  defp event_config_cache_key(event_id), do: "event_config:#{event_id}"
end
