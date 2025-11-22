defmodule FastCheck.Attendees.Cache do
  @moduledoc """
  Handles caching and retrieval of attendee data.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.Query
  alias FastCheck.Cache.CacheManager

  @attendee_cache_namespace "attendee"
  @attendee_cache_hit_ttl :infinity
  @attendee_cache_miss_ttl :timer.minutes(1)
  @attendee_cache_not_found :attendee_not_found
  @attendee_id_cache_prefix "attendee:id"
  @attendee_id_cache_ttl :timer.minutes(30)
  @event_attendees_cache_prefix "attendees:event"
  @event_attendees_cache_ttl :timer.minutes(5)

  @doc """
  Fetches a single attendee by ticket code within an event, leveraging the
  attendee cache for faster lookups.
  """
  @spec get_attendee_by_ticket_code(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee_by_ticket_code(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    cache_key = attendee_cache_key(event_id, ticket_code)

    try do
      case CacheManager.get_attendee(event_id, ticket_code) do
        {:ok, %Attendee{} = attendee} ->
          Logger.debug("Attendee cache hit for #{cache_key}")
          attendee

        {:ok, @attendee_cache_not_found} ->
          Logger.debug("Attendee cache hit (not found) for #{cache_key}")
          nil

        {:ok, nil} ->
          Logger.debug("Attendee cache miss for #{cache_key}")
          fetch_attendee_with_cache(event_id, ticket_code, cache_key)

        {:error, :cache_unavailable} ->
          Logger.debug("Cache unavailable for #{cache_key}, skipping cache")
          Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code)

        {:error, reason} ->
          Logger.warning("Attendee cache lookup failed for #{cache_key}: #{inspect(reason)}")
          fetch_attendee_with_cache(event_id, ticket_code, cache_key)
      end
    rescue
      exception ->
        Logger.warning(
          "Attendee cache lookup raised for #{cache_key}: #{Exception.message(exception)}"
        )

        fetch_attendee_with_cache(event_id, ticket_code, cache_key)
    end
  end

  def get_attendee_by_ticket_code(_, _), do: nil

  @doc """
  Fetches a single attendee by id using a dedicated cache entry.
  """
  @spec get_attendee!(integer()) :: Attendee.t()
  def get_attendee!(attendee_id) when is_integer(attendee_id) and attendee_id > 0 do
    cache_key = attendee_id_cache_key(attendee_id)

    try do
      case CacheManager.get(cache_key) do
        {:ok, %Attendee{} = attendee} ->
          Logger.debug("Attendee id cache hit for #{cache_key}")
          attendee

        {:ok, nil} ->
          Logger.debug("Attendee id cache miss for #{cache_key}")
          fetch_attendee_by_id(attendee_id, cache_key, true)

        {:error, :cache_unavailable} ->
          Logger.debug("Attendee id cache unavailable for #{cache_key}, skipping cache")
          Repo.get!(Attendee, attendee_id)

        {:error, reason} ->
          Logger.warning("Attendee id cache lookup failed for #{cache_key}: #{inspect(reason)}")
          fetch_attendee_by_id(attendee_id, cache_key, false)
      end
    rescue
      exception ->
        Logger.warning(
          "Attendee id cache lookup raised for #{cache_key}: #{Exception.message(exception)}"
        )

        Repo.get!(Attendee, attendee_id)
    end
  end

  def get_attendee!(attendee_id), do: Repo.get!(Attendee, attendee_id)

  @doc """
  Removes the cached attendee lookup by id so future reads hit the database.
  """
  @spec delete_attendee_id_cache(integer()) :: :ok | :error
  def delete_attendee_id_cache(attendee_id) when is_integer(attendee_id) and attendee_id > 0 do
    cache_key = attendee_id_cache_key(attendee_id)

    try do
      case CacheManager.delete(cache_key) do
        {:ok, true} ->
          Logger.debug("Deleted attendee id cache entry for #{cache_key}")
          :ok

        {:error, :cache_unavailable} ->
          Logger.debug("Cache unavailable when deleting #{cache_key}, skipping invalidation")
          :ok

        {:error, reason} ->
          Logger.warning(
            "Unable to delete attendee id cache entry for #{cache_key}: #{inspect(reason)}"
          )

          :error
      end
    rescue
      exception ->
        Logger.warning(
          "Attendee id cache delete raised for #{cache_key}: #{Exception.message(exception)}"
        )

        :error
    end
  end

  def delete_attendee_id_cache(_), do: :ok

  @doc """
  Retrieves and caches the attendee list for an event for five minutes to
  accelerate dashboard views and repeated queries.
  """
  @spec get_attendees_by_event(integer(), keyword()) :: [Attendee.t()]
  def get_attendees_by_event(event_id, opts \\ [])

  def get_attendees_by_event(event_id, opts)
      when is_integer(event_id) do
    force_refresh = Keyword.get(opts, :force_refresh, false)
    cache_key = attendees_by_event_cache_key(event_id)

    if force_refresh do
      fetch_and_cache_attendees_by_event(event_id, cache_key)
    else
      case CacheManager.get(cache_key) do
        {:ok, nil} ->
          fetch_and_cache_attendees_by_event(event_id, cache_key)

        {:ok, attendees} when is_list(attendees) ->
          attendees

        {:error, reason} ->
          Logger.warning(
            "Attendee list cache read failed for event #{event_id}: #{inspect(reason)}"
          )

          fetch_and_cache_attendees_by_event(event_id, cache_key)
      end
    end
  rescue
    exception ->
      Logger.warning(
        "Attendee list cache lookup raised for event #{event_id}: #{Exception.message(exception)}"
      )

      list_event_attendees(event_id)
  end

  def get_attendees_by_event(_, _), do: []

  @doc """
  Removes the cached attendee list for the provided event so future reads hit
  the database and rebuild the snapshot.
  """
  @spec invalidate_attendees_by_event_cache(integer()) :: :ok | :error
  def invalidate_attendees_by_event_cache(event_id) when is_integer(event_id) do
    cache_key = attendees_by_event_cache_key(event_id)

    case CacheManager.delete(cache_key) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to delete attendees cache for event #{event_id}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    exception ->
      Logger.warning(
        "Attendee list cache delete raised for event #{event_id}: #{Exception.message(exception)}"
      )

      :error
  end

  def invalidate_attendees_by_event_cache(_), do: :ok

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.
  """
  @spec list_event_attendees(integer()) :: [Attendee.t()]
  def list_event_attendees(event_id) do
    Query.list_event_attendees(event_id)
  end

  # Private Helpers

  defp fetch_attendee_with_cache(event_id, ticket_code, cache_key) do
    case Query.get_attendee_by_ticket_code(event_id, ticket_code) do
      %Attendee{} = attendee ->
        persist_attendee_cache(event_id, ticket_code, cache_key, attendee)
        attendee

      nil ->
        persist_attendee_miss(cache_key)
        nil
    end
  end

  defp persist_attendee_cache(event_id, ticket_code, cache_key, attendee) do
    case CacheManager.put_attendee(event_id, ticket_code, attendee) do
      {:ok, true} ->
        Logger.debug(
          "Stored attendee cache entry for #{cache_key} (ttl=#{inspect(@attendee_cache_hit_ttl)})"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Unable to store attendee cache entry for #{cache_key}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp persist_attendee_miss(cache_key) do
    case CacheManager.put(cache_key, @attendee_cache_not_found, ttl: @attendee_cache_miss_ttl) do
      {:ok, true} ->
        Logger.debug(
          "Stored attendee cache miss sentinel for #{cache_key} (ttl=#{@attendee_cache_miss_ttl}ms)"
        )

        :ok

      {:error, reason} ->
        Logger.warning("Unable to cache attendee miss for #{cache_key}: #{inspect(reason)}")
        :error
    end
  end

  defp attendee_cache_key(event_id, ticket_code) do
    "#{@attendee_cache_namespace}:#{event_id}:#{ticket_code}"
  end

  defp attendee_id_cache_key(attendee_id), do: "#{@attendee_id_cache_prefix}:#{attendee_id}"

  defp fetch_attendee_by_id(attendee_id, cache_key, should_cache?) do
    attendee = Repo.get!(Attendee, attendee_id)

    if should_cache? do
      persist_attendee_id_cache(cache_key, attendee)
    end

    attendee
  end

  defp persist_attendee_id_cache(cache_key, attendee) do
    case CacheManager.put(cache_key, attendee, ttl: @attendee_id_cache_ttl) do
      {:ok, true} ->
        Logger.debug(
          "Stored attendee id cache entry for #{cache_key} (ttl=#{inspect(@attendee_id_cache_ttl)}ms)"
        )

        :ok

      {:error, :cache_unavailable} ->
        Logger.debug("Skipping attendee id cache write for #{cache_key} (cache unavailable)")
        :ok

      {:error, reason} ->
        Logger.warning(
          "Unable to store attendee id cache entry for #{cache_key}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    exception ->
      Logger.warning(
        "Attendee id cache write raised for #{cache_key}: #{Exception.message(exception)}"
      )

      :error
  end

  defp fetch_and_cache_attendees_by_event(event_id, cache_key) do
    attendees = list_event_attendees(event_id)

    case CacheManager.put(cache_key, attendees, ttl: @event_attendees_cache_ttl) do
      {:ok, true} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to store attendees cache for event #{event_id}: #{inspect(reason)}"
        )

        :error
    end

    attendees
  end

  defp attendees_by_event_cache_key(event_id), do: "#{@event_attendees_cache_prefix}:#{event_id}"
end
