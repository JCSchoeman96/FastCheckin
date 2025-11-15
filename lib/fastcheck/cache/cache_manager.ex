defmodule FastCheck.Cache.CacheManager do
  @moduledoc """
  Centralized cache coordination for configuration and occupancy data.

  Uses Cachex for in-memory storage of ticket configurations and Redix/Redis
  for the hot path occupancy counters that update multiple times per second.
  All functions gracefully fall back to database queries when Redis is
  unavailable so the check-in flow never blocks.
  """

  require Logger
  import Ecto.Query

  alias Phoenix.PubSub
  alias PetalBlueprint.Repo
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Attendees.{Attendee, CheckIn}

  @cache_name :fastcheck_cache
  @pubsub PetalBlueprint.PubSub
  @occupancy_counter_ttl 3600
  @default_cache_ttl [
    ticket_config: :timer.hours(1),
    event_metadata: :timer.hours(6),
    occupancy: :timer.seconds(10)
  ]

  @type ticket_config_response ::
          {:ok,
           %{
             allowed_checkins: non_neg_integer(),
             time_basis: String.t() | nil,
             window_start: Date.t() | nil,
             window_end: Date.t() | nil
           }} | {:error, String.t()}

  @doc """
  Retrieves a ticket configuration for an event/ticket type pair using Cachex
  with a one-hour TTL. When the cache is bypassed, the record is loaded from
  the `check_in_configurations` table and inserted into the cache.
  """
  @spec cache_get_ticket_config(integer(), String.t() | nil) :: ticket_config_response
  def cache_get_ticket_config(event_id, ticket_type)
      when is_integer(event_id) and (is_binary(ticket_type) or is_nil(ticket_type)) do
    normalized_type = normalize_ticket_type(ticket_type)
    cache_key = config_cache_key(event_id, normalized_type)

    with {:ok, cached} <- fetch_cached_config(cache_key) do
      {:ok, cached}
    else
      {:miss, reason} ->
        Logger.debug("Cache MISS: #{cache_key} (#{reason})")

        case fetch_ticket_config_from_db(event_id, normalized_type) do
          {:ok, config} ->
            persist_config_cache(cache_key, config)
            {:ok, config}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cache_get_ticket_config(_event_id, _ticket_type), do: {:error, "INVALID_PARAMS"}

  @doc """
  Returns the current occupancy snapshot for an event. The hot path reads from
  Redis (with a 10-second TTL) and falls back to aggregate database queries on
  a cache miss.
  """
  @spec get_cached_occupancy(integer()) ::
          {:ok,
           %{
             inside: non_neg_integer(),
             total_entries: non_neg_integer(),
             total_exits: non_neg_integer(),
             total_attendees: non_neg_integer(),
             percentage: float(),
             updated_at: DateTime.t() | String.t()
           }} | {:error, String.t()}
  def get_cached_occupancy(event_id) when is_integer(event_id) do
    keys = occupancy_keys(event_id)

    case fetch_occupancy_from_redis(keys) do
      {:ok, snapshot} ->
        Logger.debug("Cache HIT: #{keys.current}")
        {:ok, snapshot}

      {:error, :miss} ->
        Logger.debug("Cache MISS: #{keys.current}")
        refresh_occupancy_from_db(event_id, keys)

      {:error, reason} ->
        Logger.warn("Occupancy cache unavailable for event #{event_id}: #{inspect(reason)}")
        refresh_occupancy_from_db(event_id, keys)
    end
  end

  def get_cached_occupancy(_event_id), do: {:error, "INVALID_EVENT"}

  @doc """
  Atomically increments or decrements the live occupancy counters for an
  event inside Redis and broadcasts the updated totals to `OccupancyLive`.
  """
  @spec increment_occupancy(integer(), String.t()) :: {:ok, non_neg_integer()}
  def increment_occupancy(event_id, change_type)
      when is_integer(event_id) and change_type in ["entry", "exit"] do
    delta = if(change_type == "entry", do: 1, else: -1)
    keys = occupancy_keys(event_id)

    new_count =
      case adjust_redis_occupancy(keys, change_type, delta) do
        {:ok, count} ->
          count

        {:error, reason} ->
          Logger.warn(
            "Redis occupancy update failed for event #{event_id}: #{inspect(reason)}"
          )

          case refresh_occupancy_from_db(event_id, keys) do
            {:ok, snapshot} -> snapshot.inside
            {:error, _} -> 0
          end
      end

    broadcast_occupancy(event_id, new_count, change_type)
    {:ok, new_count}
  end

  def increment_occupancy(_event_id, _change_type), do: {:ok, 0}

  @doc """
  Clears cached entries related to an event. Supports config-only,
  occupancy-only, or full invalidations.
  """
  @spec invalidate_cache(integer(), String.t()) :: {:ok, String.t()}
  def invalidate_cache(event_id, cache_type)
      when is_integer(event_id) and cache_type in ["config", "occupancy", "all"] do
    Logger.warn("Cache invalidation: #{cache_type} for event #{event_id}")

    case cache_type do
      "config" -> clear_config_cache(event_id)
      "occupancy" -> clear_occupancy_cache(event_id)
      "all" ->
        clear_config_cache(event_id)
        clear_occupancy_cache(event_id)
    end

    {:ok, "CACHE_INVALIDATED"}
  end

  def invalidate_cache(_event_id, _cache_type), do: {:ok, "CACHE_INVALIDATED"}

  defp refresh_occupancy_from_db(event_id, keys) do
    with {:ok, snapshot} <- load_occupancy_snapshot(event_id) do
      persist_occupancy_snapshot(keys, snapshot)
      {:ok, snapshot}
    end
  end

  defp fetch_cached_config(cache_key) do
    if cache_available?() do
      case Cachex.get(@cache_name, cache_key) do
        {:ok, nil} -> {:miss, :empty}
        {:ok, cached} ->
          ttl = ttl_for(:ticket_config)
          Cachex.expire(@cache_name, cache_key, ttl)
          Logger.debug("Cache HIT: #{cache_key}")
          {:ok, cached}

        {:error, reason} ->
          Logger.warn("Cache lookup failed for #{cache_key}: #{inspect(reason)}")
          {:miss, :error}
      end
    else
      {:miss, :disabled}
    end
  end

  defp persist_config_cache(_cache_key, _config) when not cache_available?, do: :ok

  defp persist_config_cache(cache_key, config) do
    ttl = ttl_for(:ticket_config)
    :ok = Cachex.put(@cache_name, cache_key, config, ttl: ttl)
  rescue
    exception ->
      Logger.warn(
        "Unable to persist ticket config cache #{cache_key}: #{Exception.message(exception)}"
      )
      :ok
  end

  defp fetch_ticket_config_from_db(event_id, ticket_type) do
    query =
      from(c in CheckInConfiguration,
        where:
          c.event_id == ^event_id and
            fragment("lower(?)", c.ticket_type) == ^ticket_type,
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, "NOT_FOUND"}

      %CheckInConfiguration{} = config ->
        {:ok,
         %{
           allowed_checkins: normalize_count(config.daily_check_in_limit || config.allowed_checkins),
           time_basis: config.time_basis,
           window_start: config.check_in_window_start,
           window_end: config.check_in_window_end
         }}
    end
  rescue
    exception ->
      Logger.error(
        "Failed to load ticket configuration for event #{event_id}: #{Exception.message(exception)}"
      )

      {:error, "NOT_FOUND"}
  end

  defp fetch_occupancy_from_redis(keys) do
    with true <- redis_available?(),
         {:ok, [current, entries, exits, total, updated_at]} <-
           redis_command([
             "MGET",
             keys.current,
             keys.entries,
             keys.exits,
             keys.total,
             keys.updated_at
           ]),
         false <- Enum.any?([current, entries, exits, total, updated_at], &is_nil/1) do
      {:ok,
       %{
         inside: parse_int(current),
         total_entries: parse_int(entries),
         total_exits: parse_int(exits),
         total_attendees: parse_int(total),
         percentage: percentage(parse_int(current), parse_int(total)),
         updated_at: parse_timestamp(updated_at)
       }}
    else
      _ -> {:error, :miss}
    end
  end

  defp adjust_redis_occupancy(_keys, _change_type, _delta) when not redis_available?(),
    do: {:error, :redis_disabled}

  defp adjust_redis_occupancy(keys, change_type, delta) do
    with {:ok, count} <- redis_command(["INCRBY", keys.current, delta]) do
      sanitized = max(count, 0)
      if sanitized != count, do: redis_command(["SET", keys.current, sanitized])
      redis_command(["EXPIRE", keys.current, @occupancy_counter_ttl])

      counter_key = if(change_type == "entry", do: keys.entries, else: keys.exits)
      redis_command(["INCR", counter_key])
      redis_command(["EXPIRE", counter_key, @occupancy_counter_ttl])

      redis_command(["SET", keys.updated_at, iso_now()])
      redis_command(["EXPIRE", keys.updated_at, @occupancy_counter_ttl])

      {:ok, sanitized}
    end
  end

  defp load_occupancy_snapshot(event_id) do
    inside =
      Repo.one(
        from(a in Attendee,
          where: a.event_id == ^event_id and a.is_currently_inside == true,
          select: count(a.id)
        )
      )
      |> normalize_count()

    total_entries =
      Repo.one(
        from(c in CheckIn,
          where: c.event_id == ^event_id and c.status in ["success", "manual", "entry"],
          select: count(c.id)
        )
      )
      |> normalize_count()

    total_exits =
      Repo.one(
        from(c in CheckIn,
          where: c.event_id == ^event_id and c.status in ["checked_out", "exit"],
          select: count(c.id)
        )
      )
      |> normalize_count()

    total_attendees =
      Repo.one(from(a in Attendee, where: a.event_id == ^event_id, select: count(a.id)))
      |> normalize_count()

    {:ok,
     %{
       inside: inside,
       total_entries: total_entries,
       total_exits: total_exits,
       total_attendees: total_attendees,
       percentage: percentage(inside, total_attendees),
       updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
     }}
  rescue
    exception ->
      Logger.error(
        "Failed to compute occupancy snapshot for event #{event_id}: #{Exception.message(exception)}"
      )

      {:error, "OCCUPANCY_UNAVAILABLE"}
  end

  defp persist_occupancy_snapshot(_keys, _snapshot) when not redis_available?, do: :ok

  defp persist_occupancy_snapshot(keys, snapshot) do
    ttl = occupancy_ttl_seconds()

    Enum.each(
      [
        {keys.current, snapshot.inside},
        {keys.entries, snapshot.total_entries},
        {keys.exits, snapshot.total_exits},
        {keys.total, snapshot.total_attendees},
        {keys.updated_at, DateTime.to_iso8601(snapshot.updated_at)}
      ],
      fn {key, value} ->
        redis_command(["SETEX", key, ttl, to_string(value)])
      end
    )
  end

  defp broadcast_occupancy(event_id, count, change_type) do
    PubSub.broadcast(@pubsub, "event:#{event_id}:occupancy", {:occupancy_changed, count, change_type})
    :ok
  end

  defp clear_config_cache(_event_id) when not cache_available?, do: :ok

  defp clear_config_cache(event_id) do
    case Cachex.keys(@cache_name) do
      {:ok, keys} ->
        keys
        |> Enum.filter(&String.starts_with?(&1, "config:event:#{event_id}:"))
        |> Enum.each(&Cachex.del(@cache_name, &1))

      {:error, reason} ->
        Logger.warn("Unable to enumerate Cachex keys for invalidation: #{inspect(reason)}")
    end
  end

  defp clear_occupancy_cache(event_id) do
    keys = Map.values(occupancy_keys(event_id))
    redis_command(["DEL" | keys])
    :ok
  end

  defp occupancy_keys(event_id) do
    prefix = "occupancy:#{event_id}"

    %{
      current: "#{prefix}:current",
      entries: "#{prefix}:entries_today",
      exits: "#{prefix}:exits_today",
      total: "#{prefix}:total",
      updated_at: "#{prefix}:updated_at"
    }
  end

  defp config_cache_key(event_id, ticket_type),
    do: "config:event:#{event_id}:type:#{ticket_type}"

  defp normalize_ticket_type(nil), do: "default"

  defp normalize_ticket_type(type) do
    type
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "default"
      other -> other
    end
  end

  defp ttl_for(key) do
    config = Application.get_env(:fastcheck, :cache_ttl, @default_cache_ttl)
    Keyword.get(config, key, Keyword.get(@default_cache_ttl, key))
  end

  defp occupancy_ttl_seconds do
    ttl_for(:occupancy)
    |> div(1000)
    |> max(1)
  end

  defp cache_enabled?, do: Application.get_env(:fastcheck, :cache_enabled, true)

  defp cache_available? do
    cache_enabled?() and Process.whereis(@cache_name)
  end

  defp redis_available? do
    cache_enabled?() and match?(pid when is_pid(pid), Process.whereis(:redix))
  end

  defp redis_command(_command) when not redis_available?, do: {:error, :redis_unavailable}

  defp redis_command(command) do
    Redix.command(:redix, command)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp percentage(_part, total) when total <= 0, do: 0.0
  defp percentage(part, total), do: Float.round(part / total * 100, 2)

  defp parse_int(nil), do: 0

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(_value), do: 0

  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> value
    end
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp normalize_count(nil), do: 0
  defp normalize_count(value) when is_integer(value), do: max(value, 0)
  defp normalize_count(_value), do: 0
end
