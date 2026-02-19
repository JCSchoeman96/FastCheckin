defmodule FastCheck.Events.Stats do
  @moduledoc """
  Handles event statistics, occupancy tracking, and advanced analytics.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Repo
  alias FastCheck.Events.Event
  alias FastCheck.Attendees
  alias FastCheck.Attendees.{Attendee, CheckIn}
  alias FastCheck.Cache.CacheManager
  alias FastCheck.TickeraClient
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Events.Cache

  @default_event_stats %{
    total_tickets: 0,
    total: 0,
    checked_in: 0,
    pending: 0,
    no_shows: 0,
    occupancy_percent: 0.0,
    percentage: 0.0
  }

  @stats_ttl :timer.minutes(1)
  @occupancy_task_timeout 15_000

  @doc """
  Returns cached roll-up statistics for an event including totals and
  occupancy percentage.
  """
  @spec get_event_stats(integer()) :: map()
  def get_event_stats(event_id) when is_integer(event_id) and event_id > 0 do
    cache_key = stats_cache_key(event_id)

    case CacheManager.get(cache_key) do
      {:ok, stats} when is_map(stats) ->
        Logger.debug(fn -> {"stats cache hit", event_id: event_id} end)
        stats

      {:ok, nil} ->
        Logger.debug(fn -> {"stats cache miss", event_id: event_id} end)
        fetch_and_cache_event_stats(event_id)

      {:ok, other} ->
        Logger.debug(fn ->
          {"stats cache miss due to unexpected payload", payload: inspect(other)}
        end)

        fetch_and_cache_event_stats(event_id)

      {:error, reason} ->
        Logger.warning(fn ->
          {"stats cache unavailable", event_id: event_id, reason: inspect(reason)}
        end)

        compute_event_stats(event_id)
    end
  end

  def get_event_stats(_), do: @default_event_stats

  @doc """
  Fetches an event and refreshes its `checked_in_count` statistic based on the
  number of attendees with a populated `checked_in_at` timestamp.
  """
  @spec get_event_with_stats(integer()) :: Event.t()
  def get_event_with_stats(event_id) do
    event = Cache.get_event!(event_id)

    checked_in_count =
      from(a in Attendee,
        where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
        select: count(a.id)
      )
      |> Repo.one()

    case event |> Changeset.change(%{checked_in_count: checked_in_count}) |> Repo.update() do
      {:ok, updated} ->
        Cache.invalidate_event_cache(updated.id)
        Cache.invalidate_events_list_cache()
        updated

      {:error, changeset} ->
        Logger.error("Failed to update stats for event #{event_id}: #{inspect(changeset.errors)}")
        %{event | checked_in_count: checked_in_count}
    end
  end

  @doc """
  Updates the cached occupancy count when a guest enters or exits and
  broadcasts the new totals via PubSub.
  """
  @spec update_occupancy(integer(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def update_occupancy(event_id, delta) when is_integer(event_id) and delta in [-1, 1] do
    case Repo.get(Event, event_id) do
      nil ->
        {:error, :event_not_found}

      %Event{} = event ->
        capacity = normalize_non_neg_integer(event.total_tickets || 0)
        {base_inside, snapshot} = occupancy_snapshot_for_update(event_id)

        new_inside = max(base_inside + delta, 0)
        total_entries = Map.get(snapshot, :total_entries, 0) + max(delta, 0)
        total_exits = Map.get(snapshot, :total_exits, 0) + max(-delta, 0)

        updated_snapshot =
          snapshot
          |> Map.put(:inside, new_inside)
          |> Map.put(:total_entries, total_entries)
          |> Map.put(:total_exits, total_exits)
          |> Map.put(:capacity, capacity)
          |> Map.put(:percentage, compute_percentage(new_inside, capacity))
          |> Map.put(:updated_at, DateTime.utc_now())

        case CacheManager.put_event_occupancy(event_id, updated_snapshot) do
          {:ok, true} ->
            Logger.debug(fn ->
              {"occupancy cache updated", event_id: event_id, inside: new_inside}
            end)

          {:error, reason} ->
            Logger.warning(fn ->
              {"occupancy cache update failed", event_id: event_id, reason: inspect(reason)}
            end)
        end

        broadcast_occupancy_update(event_id, new_inside)
        {:ok, new_inside}
    end
  rescue
    exception ->
      Logger.error(
        "Occupancy update failed for event #{event_id}: #{Exception.message(exception)}"
      )

      {:error, :occupancy_update_failed}
  end

  def update_occupancy(_event_id, _delta), do: {:error, :invalid_delta}

  @doc """
  Computes advanced analytics for an event including attendee, entrance, and
  configuration derived metrics.
  """
  @spec get_event_advanced_stats(integer()) :: map()
  def get_event_advanced_stats(event_id) when is_integer(event_id) do
    try do
      attendee_scope = from(a in Attendee, where: a.event_id == ^event_id)
      start_of_day = beginning_of_day_utc()

      total_attendees =
        attendee_scope |> select([a], count(a.id)) |> Repo.one() |> normalize_count()

      checked_in =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at))
        |> select([a], count(a.id))
        |> Repo.one()
        |> normalize_count()

      pending = max(total_attendees - checked_in, 0)

      {currently_inside, occupancy_percentage, cached_entry_total, cached_exit_total} =
        case CacheManager.get_cached_occupancy(event_id) do
          {:ok, %{inside: inside, percentage: pct, total_entries: ent, total_exits: ext}} ->
            {inside, pct, ent, ext}

          _ ->
            fallback_inside =
              attendee_scope
              |> where([a], not is_nil(a.checked_in_at))
              |> where([a], is_nil(a.checked_out_at) or a.checked_out_at < a.checked_in_at)
              |> select([a], count(a.id))
              |> Repo.one()
              |> normalize_count()

            {fallback_inside, compute_percentage(fallback_inside, total_attendees), nil, nil}
        end

      scans_today =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at) and a.checked_in_at >= ^start_of_day)
        |> select([a], count(a.id))
        |> Repo.one()
        |> normalize_count()

      per_entrance = fetch_per_entrance_stats(event_id)

      total_entries =
        cached_entry_total ||
          Enum.reduce(per_entrance, 0, fn stat, acc -> acc + normalize_count(stat.entries) end)

      total_exits =
        cached_exit_total ||
          Enum.reduce(per_entrance, 0, fn stat, acc -> acc + normalize_count(stat.exits) end)

      avg_session_seconds =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at) and not is_nil(a.checked_out_at))
        |> select(
          [a],
          fragment("avg(extract(epoch from (? - ?)))", a.checked_out_at, a.checked_in_at)
        )
        |> Repo.one()
        |> normalize_float()

      average_session_minutes =
        avg_session_seconds
        |> Kernel./(60)
        |> Float.round(2)
        |> max(0.0)

      configs = Repo.all(from(c in CheckInConfiguration, where: c.event_id == ^event_id))

      total_config_limit =
        configs
        |> Enum.reduce(0, fn config, acc ->
          limit = config.daily_check_in_limit || config.allowed_checkins || 0
          acc + normalize_count(limit)
        end)

      available_tomorrow = max(total_config_limit - scans_today, 0)

      time_basis_info =
        configs
        |> Enum.map(&compact_time_basis_info/1)
        |> Enum.reject(&(&1 == %{}))

      %{
        total_attendees: total_attendees,
        checked_in: checked_in,
        pending: pending,
        checked_in_percentage: compute_percentage(checked_in, total_attendees),
        currently_inside: currently_inside,
        scans_today: scans_today,
        per_entrance: per_entrance,
        total_entries: total_entries,
        total_exits: total_exits,
        occupancy_percentage: occupancy_percentage,
        available_tomorrow: available_tomorrow,
        time_basis_info: time_basis_info,
        average_session_duration_minutes: average_session_minutes
      }
    rescue
      exception ->
        Logger.error(
          "Failed to compute advanced stats for event #{event_id}: #{Exception.message(exception)}"
        )

        default_advanced_stats()
    end
  end

  def get_event_advanced_stats(_), do: default_advanced_stats()

  @doc """
  Fetches live occupancy information for an event using the Tickera API,
  persists the latest statistics, and broadcasts the updated totals over PubSub.
  """
  @spec update_event_occupancy_live(integer()) :: {:ok, map()} | {:error, String.t()}
  def update_event_occupancy_live(event_id) when is_integer(event_id) do
    # We need to access private helpers from Events or move them here.
    # ensure_event_credentials is in Events.
    # We can't call private functions.
    # I'll assume Events will expose a helper or I should move ensure_event_credentials logic here?
    # ensure_event_credentials uses get_tickera_api_key which is now in Sync.
    # So I should use Sync.get_tickera_api_key.
    # But I need the event first.
    with %Event{} = event <- Repo.get(Event, event_id),
         {:ok, site_url, api_key} <- ensure_event_credentials(event),
         {:ok, payload} <- fetch_live_occupancy(site_url, api_key),
         {:ok, {occupancy_map, missing_fields}} <- extract_live_occupancy(payload),
         :ok <- persist_live_occupancy(event_id, occupancy_map) do
      log_live_occupancy(event_id, occupancy_map, missing_fields)
      broadcast_live_occupancy(event_id, occupancy_map.current_occupancy)
      {:ok, occupancy_map}
    else
      nil ->
        {:error, "EVENT_NOT_FOUND"}

      {:error, "MISSING_CREDENTIALS"} ->
        {:error, "MISSING_CREDENTIALS"}

      {:error, :decryption_failed} ->
        Logger.error(
          "Live occupancy update failed for event #{event_id}: credential decryption failed"
        )

        {:error, "CREDENTIAL_DECRYPTION_FAILED"}

      {:error, code, message} ->
        Logger.error("Live occupancy update failed for event #{event_id}: #{code} – #{message}")
        {:error, "OCCUPANCY_FETCH_FAILED"}

      {:error, reason} ->
        Logger.error("Live occupancy update failed for event #{event_id}: #{inspect(reason)}")
        {:error, "OCCUPANCY_FETCH_FAILED"}
    end
  end

  @doc """
  Broadcasts a sanitized occupancy update for the given event.
  """
  @spec broadcast_occupancy_update(integer(), integer()) :: :ok | {:error, atom()}
  def broadcast_occupancy_update(event_id, inside_count)
      when is_integer(event_id) and is_integer(inside_count) and event_id > 0 do
    case Repo.get(Event, event_id) do
      %Event{} = event ->
        payload = build_occupancy_payload(event, inside_count)

        try do
          Phoenix.PubSub.broadcast!(
            FastCheck.PubSub,
            occupancy_topic(event_id),
            {:occupancy_updated, payload}
          )
        rescue
          exception ->
            Logger.error(
              "Failed to broadcast occupancy update for event #{event_id}: #{Exception.message(exception)}"
            )

            {:error, :broadcast_failed}
        end

      nil ->
        Logger.error("Unable to broadcast occupancy update: event #{event_id} not found")
        {:error, :event_not_found}
    end
  end

  def broadcast_occupancy_update(_event_id, _inside_count), do: {:error, :invalid_event}

  def invalidate_event_stats_cache(event_id) do
    case CacheManager.delete(stats_cache_key(event_id)) do
      {:ok, _} ->
        Logger.debug(fn -> {"stats cache invalidated", event_id: event_id} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"stats cache invalidate failed", event_id: event_id, reason: inspect(reason)}
        end)

        :error
    end
  end

  def invalidate_occupancy_cache(event_id) do
    pattern = occupancy_pattern(event_id)

    case CacheManager.invalidate_pattern(pattern) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"occupancy pattern invalidation failed", event_id: event_id, reason: inspect(reason)}
        end)

        :error
    end

    case CacheManager.delete(occupancy_cache_key(event_id)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"occupancy cache delete failed", event_id: event_id, reason: inspect(reason)}
        end)

        :error
    end
  end

  def broadcast_event_stats(event_id, stats) do
    Phoenix.PubSub.broadcast(
      FastCheck.PubSub,
      stats_topic(event_id),
      {:event_stats_updated, event_id, stats}
    )
  rescue
    exception ->
      Logger.error(
        "Failed to broadcast stats for event #{event_id}: #{Exception.message(exception)}"
      )

      {:error, :broadcast_failed}
  end

  @doc """
  Broadcasts the current occupancy breakdown for an event via PubSub.

  This runs asynchronously to avoid blocking the caller. Fetches the latest
  breakdown from the Attendees context and broadcasts it to subscribers.
  """
  @spec broadcast_occupancy_breakdown(integer()) :: :ok
  def broadcast_occupancy_breakdown(event_id) when is_integer(event_id) do
    Task.start(fn ->
      try do
        # Compute directly from DB for broadcast so we don't warm or reuse the
        # short-lived UI cache with potentially stale intermediate values.
        breakdown = FastCheck.Attendees.Query.compute_occupancy_breakdown(event_id)

        Phoenix.PubSub.broadcast(
          FastCheck.PubSub,
          "event:#{event_id}:occupancy",
          {:occupancy_breakdown_updated, event_id, breakdown}
        )
      rescue
        exception ->
          Logger.error(
            "Failed to broadcast occupancy breakdown for event #{event_id}: #{Exception.message(exception)}"
          )
      end
    end)

    :ok
  end

  def broadcast_occupancy_breakdown(_), do: :ok

  # Private Helpers

  defp fetch_and_cache_event_stats(event_id) do
    stats = compute_event_stats(event_id)
    cache_event_stats(event_id, stats)
    stats
  end

  defp compute_event_stats(event_id) do
    base_stats = Attendees.get_event_stats(event_id)
    event = Cache.get_event!(event_id)

    total_tickets =
      normalize_non_neg_integer(event.total_tickets || Map.get(base_stats, :total, 0))

    checked_in = normalize_count(Map.get(base_stats, :checked_in, 0))
    pending = normalize_count(Map.get(base_stats, :pending, 0))
    no_shows = max(total_tickets - checked_in, 0)

    occupancy_percent =
      if total_tickets <= 0 do
        0.0
      else
        Float.round(checked_in / total_tickets * 100, 2)
      end

    Map.merge(@default_event_stats, %{
      total_tickets: total_tickets,
      total: total_tickets,
      checked_in: checked_in,
      pending: pending,
      no_shows: no_shows,
      occupancy_percent: occupancy_percent,
      percentage: occupancy_percent
    })
  rescue
    exception ->
      Logger.error(
        "Failed to compute stats for event #{event_id}: #{Exception.message(exception)}"
      )

      @default_event_stats
  end

  defp cache_event_stats(event_id, stats) do
    case CacheManager.put(stats_cache_key(event_id), stats, ttl: @stats_ttl) do
      {:ok, true} ->
        :ok

      {:error, reason} ->
        Logger.warning(fn ->
          {"stats cache write failed", event_id: event_id, reason: inspect(reason)}
        end)

        :error
    end
  end

  defp occupancy_snapshot_for_update(event_id) do
    case CacheManager.get_cached_occupancy(event_id) do
      {:ok, %{} = snapshot} ->
        updated_at = Map.get(snapshot, :updated_at)

        inside =
          if is_nil(updated_at) do
            recalc = recalculate_occupancy_from_db(event_id)
            recalc
          else
            normalize_count(Map.get(snapshot, :inside, 0))
          end

        {inside, Map.put(snapshot, :inside, inside)}

      {:error, reason} ->
        Logger.warning(fn ->
          {"occupancy cache read failed", event_id: event_id, reason: inspect(reason)}
        end)

        inside = recalculate_occupancy_from_db(event_id)

        snapshot = %{
          inside: inside,
          total_entries: 0,
          total_exits: 0,
          capacity: nil,
          percentage: 0.0,
          updated_at: nil
        }

        {inside, snapshot}
    end
  end

  defp recalculate_occupancy_from_db(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
      where: is_nil(a.checked_out_at) or a.checked_out_at < a.checked_in_at,
      select: count(a.id)
    )
    |> Repo.one()
    |> normalize_count()
  end

  defp ensure_event_credentials(%Event{tickera_site_url: site_url} = event) do
    cond do
      not present?(site_url) ->
        {:error, "MISSING_CREDENTIALS"}

      true ->
        # Use Sync module to get api key
        case FastCheck.Events.Sync.get_tickera_api_key(event) do
          {:ok, api_key} -> {:ok, site_url, api_key}
          {:error, :decryption_failed} -> {:error, :decryption_failed}
        end
    end
  end

  defp ensure_event_credentials(_), do: {:error, "MISSING_CREDENTIALS"}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp fetch_live_occupancy(site_url, api_key) do
    task = Task.async(fn -> TickeraClient.get_event_occupancy(site_url, api_key) end)

    try do
      Task.await(task, @occupancy_task_timeout)
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        {:error, "TASK_TIMEOUT", "Task timed out"}

      :exit, reason ->
        {:error, "TASK_EXIT", inspect(reason)}
    end
  end

  defp extract_live_occupancy(%{} = payload) do
    per_entrance = payload |> Map.get(:per_entrance) |> ensure_map()

    base = %{
      current_occupancy: Map.get(payload, :checked_in),
      total_entries: Map.get(payload, :total_capacity),
      total_exits: Map.get(payload, :remaining),
      percentage: Map.get(payload, :occupancy_percentage),
      per_entrance: per_entrance
    }

    sanitized = %{
      current_occupancy: normalize_occupancy_integer(base.current_occupancy),
      total_entries: normalize_occupancy_integer(base.total_entries),
      total_exits: normalize_occupancy_integer(base.total_exits),
      percentage: normalize_occupancy_float(base.percentage),
      per_entrance: per_entrance
    }

    missing_fields =
      [:current_occupancy, :total_entries, :total_exits, :percentage]
      |> Enum.filter(fn key -> is_nil(Map.get(base, key)) end)

    {:ok, {sanitized, missing_fields}}
  end

  defp extract_live_occupancy(_payload), do: {:error, :invalid_payload}

  defp persist_live_occupancy(event_id, %{current_occupancy: current, per_entrance: per_gate}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    updates = [
      checked_in_count: current,
      last_occupancy_sync: now,
      occupancy_per_gate: per_gate
    ]

    case Event |> where([e], e.id == ^event_id) |> Repo.update_all(set: updates) do
      {count, _} when count > 0 ->
        Cache.invalidate_event_cache(event_id)
        Cache.invalidate_events_list_cache()
        :ok

      _ ->
        {:error, :not_updated}
    end
  end

  defp log_live_occupancy(event_id, occupancy_map, []) do
    Logger.info(
      "Live occupancy update for event #{event_id}: #{occupancy_map.current_occupancy}/#{occupancy_map.total_entries} (#{occupancy_map.percentage}%)"
    )
  end

  defp log_live_occupancy(event_id, occupancy_map, missing_fields) do
    Logger.warning(
      "Live occupancy update for event #{event_id} missing #{Enum.join(missing_fields, ", ")}: #{inspect(occupancy_map)}"
    )
  end

  defp broadcast_live_occupancy(event_id, current_occupancy) do
    Phoenix.PubSub.broadcast!(
      FastCheck.PubSub,
      "event:#{event_id}:occupancy",
      {:occupancy_changed, current_occupancy, "live_update"}
    )
  end

  defp build_occupancy_payload(%Event{} = event, inside_count) do
    sanitized_inside = normalize_non_neg_integer(inside_count)
    capacity = resolve_event_capacity(event)
    percentage = compute_percentage(sanitized_inside, capacity)

    %{
      event_id: event.id,
      inside_count: sanitized_inside,
      capacity: capacity,
      percentage: percentage
    }
  end

  defp resolve_event_capacity(%Event{total_tickets: total_tickets}) do
    normalize_non_neg_integer(total_tickets)
  end

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(value) when is_integer(value) and value < 0, do: 0
  defp normalize_non_neg_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp normalize_non_neg_integer(value) when is_float(value), do: 0
  defp normalize_non_neg_integer(_value), do: 0

  defp compute_percentage(_count, capacity) when capacity <= 0, do: 0.0

  defp compute_percentage(count, capacity) do
    count
    |> min(capacity)
    |> Kernel./(capacity)
    |> Kernel.*(100.0)
    |> Float.round(1)
  end

  defp occupancy_topic(event_id), do: "event:#{event_id}:occupancy"
  defp stats_topic(event_id), do: "event:#{event_id}:stats"
  defp stats_cache_key(event_id), do: "stats:#{event_id}"
  defp occupancy_cache_key(event_id), do: "occupancy:event:#{event_id}"
  defp occupancy_pattern(event_id), do: "occupancy:event:#{event_id}:*"

  defp normalize_occupancy_integer(value) when is_integer(value), do: value
  defp normalize_occupancy_integer(value) when is_float(value), do: trunc(value)
  defp normalize_occupancy_integer(_value), do: 0

  defp normalize_occupancy_float(value) when is_float(value), do: value
  defp normalize_occupancy_float(value) when is_integer(value), do: value / 1
  defp normalize_occupancy_float(_value), do: 0.0

  defp ensure_map(%{} = value), do: value
  defp ensure_map(_), do: %{}

  defp normalize_count(nil), do: 0
  defp normalize_count(value) when is_integer(value), do: value
  defp normalize_count(value) when is_float(value), do: round(value)

  defp normalize_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp normalize_count(%Decimal{} = value) do
    value
    |> Decimal.to_float()
    |> round()
  rescue
    _ -> 0
  end

  defp normalize_count(value) when is_boolean(value), do: if(value, do: 1, else: 0)
  defp normalize_count(_), do: 0

  defp normalize_float(nil), do: 0.0
  defp normalize_float(value) when is_float(value), do: value
  defp normalize_float(value) when is_integer(value), do: value * 1.0

  defp normalize_float(%Decimal{} = value) do
    Decimal.to_float(value)
  rescue
    _ -> 0.0
  end

  defp normalize_float(_), do: 0.0

  defp beginning_of_day_utc do
    date = Date.utc_today()

    with {:ok, naive} <- NaiveDateTime.new(date, ~T[00:00:00]),
         {:ok, utc} <- DateTime.from_naive(naive, "Etc/UTC") do
      utc
    else
      _ -> DateTime.utc_now()
    end
  end

  defp fetch_per_entrance_stats(event_id) do
    query =
      from(ci in CheckIn,
        where: ci.event_id == ^event_id,
        group_by: ci.entrance_name,
        select: %{
          entrance_name: fragment("coalesce(?, ?)", ci.entrance_name, ^"Unassigned"),
          entries:
            fragment(
              "sum(case when lower(?) = 'checked_in' then 1 else 0 end)",
              ci.status
            ),
          exits:
            fragment(
              "sum(case when lower(?) = 'checked_out' then 1 else 0 end)",
              ci.status
            ),
          inside: fragment("sum(case when lower(?) = 'inside' then 1 else 0 end)", ci.status)
        }
      )

    Repo.all(query)
    |> Enum.map(fn stat ->
      %{
        entrance_name: stat.entrance_name || "Unassigned",
        entries: normalize_count(stat.entries),
        exits: normalize_count(stat.exits),
        inside: normalize_count(stat.inside)
      }
    end)
  rescue
    exception ->
      Logger.error(
        "Failed to load entrance stats for event #{event_id}: #{Exception.message(exception)}"
      )

      []
  end

  defp compact_time_basis_info(%CheckInConfiguration{} = config) do
    %{
      ticket_type: config.ticket_type || config.ticket_name,
      ticket_name: config.ticket_name,
      time_basis: config.time_basis,
      timezone: config.time_basis_timezone,
      daily_check_in_limit: config.daily_check_in_limit,
      allowed_checkins: config.allowed_checkins
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp compact_time_basis_info(_), do: %{}

  defp default_advanced_stats do
    %{
      total_attendees: 0,
      checked_in: 0,
      pending: 0,
      checked_in_percentage: 0.0,
      currently_inside: 0,
      scans_today: 0,
      per_entrance: [],
      total_entries: 0,
      total_exits: 0,
      occupancy_percentage: 0.0,
      available_tomorrow: 0,
      time_basis_info: [],
      average_session_duration_minutes: 0.0
    }
  end
end
