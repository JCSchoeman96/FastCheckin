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

  @event_config_ttl :timer.hours(1)
  @events_list_ttl :timer.minutes(15)
  @events_list_cache_key "events:all"

  @doc """
  Retrieves an event by id using a cache-aside strategy.
  """
  @spec get_event!(integer()) :: Event.t()
  def get_event!(event_id) when is_integer(event_id) and event_id > 0 do
    case CacheManager.get(event_config_cache_key(event_id)) do
      {:ok, %Event{} = event} ->
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
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"event cache write failed", event_id: event.id, reason: inspect(reason)}
        end)

        :error
    end
  end

  # Private Helpers

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
    Event
    |> join(:left, [e], a in Attendee, on: a.event_id == e.id)
    |> group_by([e, _a], e)
    |> select_merge([_e, a], %{attendee_count: count(a.id)})
    |> Repo.all()
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
