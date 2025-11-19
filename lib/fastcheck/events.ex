defmodule FastCheck.Events do
  @moduledoc """
  Context responsible for orchestrating event lifecycle actions such as creation,
  synchronization, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Attendees.{Attendee, CheckIn}
  alias FastCheck.Repo
  alias FastCheck.{
    Attendees,
    Cache.CacheManager,
    Crypto,
    Events.CheckInConfiguration,
    Events.Event
  }
  alias FastCheck.TickeraClient
  alias Postgrex.Range

  @attr_atom_lookup %{
    "site_url" => :site_url,
    "tickera_site_url" => :tickera_site_url,
    "api_key" => :api_key,
    "tickera_api_key_encrypted" => :tickera_api_key_encrypted,
    "tickera_api_key_last4" => :tickera_api_key_last4,
    "name" => :name,
    "status" => :status,
    "entrance_name" => :entrance_name,
    "location" => :location,
    "event_date" => :event_date,
    "event_time" => :event_time,
    "tickera_start_date" => :tickera_start_date,
    "tickera_end_date" => :tickera_end_date,
    "last_sync_at" => :last_sync_at,
    "last_soft_sync_at" => :last_soft_sync_at
  }

  @credential_fields [
    :tickera_site_url,
    :tickera_api_key_encrypted,
    :tickera_api_key_last4,
    :tickera_start_date,
    :tickera_end_date,
    :status
  ]

  @config_fields [
    :ticket_type,
    :ticket_name,
    :allowed_checkins,
    :allow_reentry,
    :allowed_entrances,
    :check_in_window_start,
    :check_in_window_end,
    :check_in_window_timezone,
    :check_in_window_days,
    :check_in_window_buffer_minutes,
    :time_basis,
    :time_basis_timezone,
    :daily_check_in_limit,
    :entrance_limit,
    :limit_per_order,
    :min_per_order,
    :max_per_order,
    :status,
    :message,
    :last_checked_in_date
  ]

  @config_replace_fields (@config_fields ++ [:check_in_window, :updated_at])

  @occupancy_task_timeout 15_000
  @event_config_ttl :timer.hours(1)
  @events_list_ttl :timer.minutes(15)
  @stats_ttl :timer.minutes(1)
  @seconds_per_day 86_400

  @events_list_cache_key "events:all"
  @default_event_stats %{
    total_tickets: 0,
    total: 0,
    checked_in: 0,
    pending: 0,
    no_shows: 0,
    occupancy_percent: 0.0,
    percentage: 0.0
  }

  @doc """
  Determines an event's lifecycle state using its Tickera start and end dates
  plus the configured post-event grace period.
  """
  @spec event_lifecycle_state(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          :unknown | :upcoming | :active | :grace | :archived
  def event_lifecycle_state(event, reference_datetime \\ DateTime.utc_now())

  def event_lifecycle_state(%Event{} = event, reference_datetime) do
    now = normalize_reference_datetime(reference_datetime)
    start_time = normalize_event_datetime(event.tickera_start_date)
    end_time = normalize_event_datetime(event.tickera_end_date)
    grace_cutoff = grace_period_end(end_time)

    cond do
      is_nil(now) -> :unknown
      is_nil(start_time) and is_nil(end_time) -> :unknown
      not is_nil(start_time) and NaiveDateTime.compare(now, start_time) == :lt -> :upcoming
      is_nil(end_time) -> :active
      NaiveDateTime.compare(now, end_time) in [:lt, :eq] -> :active
      not is_nil(grace_cutoff) and NaiveDateTime.compare(now, grace_cutoff) in [:lt, :eq] -> :grace
      true -> :archived
    end
  end

  def event_lifecycle_state(_, _), do: :unknown

  @doc """
  Returns `{:ok, state}` when syncing is allowed or `{:error, {:event_archived, message}}`
  when the event has moved beyond the grace period.
  """
  @spec can_sync_event?(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          {:ok, atom()} | {:error, {:event_archived, String.t()} | {:event_missing, String.t()}}
  def can_sync_event?(event, reference_datetime \\ DateTime.utc_now())

  def can_sync_event?(%Event{} = event, reference_datetime) do
    case event_lifecycle_state(event, reference_datetime) do
      :archived -> {:error, {:event_archived, "Event archived, sync disabled"}}
      state -> {:ok, state}
    end
  end

  def can_sync_event?(_, _), do: {:error, {:event_missing, "Event not available"}}

  @doc """
  Returns `{:ok, state}` when check-ins are permitted or `{:error, {:event_archived, message}}`
  when the event is archived.
  """
  @spec can_check_in?(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          {:ok, atom()} | {:error, {:event_archived, String.t()} | {:event_missing, String.t()}}
  def can_check_in?(event, reference_datetime \\ DateTime.utc_now())

  def can_check_in?(%Event{} = event, reference_datetime) do
    case event_lifecycle_state(event, reference_datetime) do
      :archived -> {:error, {:event_archived, "Event archived, scanning disabled"}}
      state -> {:ok, state}
    end
  end

  def can_check_in?(_, _), do: {:error, {:event_missing, "Event not available"}}

  @doc """
  Creates a new event by validating Tickera credentials, fetching event
  essentials, and persisting the event record.

  ## Parameters
    * `attrs` - map of attributes such as `tickera_site_url`,
      `tickera_api_key_encrypted`, and `name`.

  ## Returns
    * `{:ok, %Event{}}` on success.
    * `{:error, reason}` when validation fails.
    * `{:error, %Ecto.Changeset{}}` when persistence fails.
  """
  @spec create_event(map()) :: {:ok, Event.t()} | {:error, String.t() | Changeset.t()}
  def create_event(attrs) when is_map(attrs) do
    site_url = fetch_attr(attrs, "tickera_site_url") || fetch_attr(attrs, "site_url")
    api_key =
      fetch_attr(attrs, "tickera_api_key_encrypted") ||
        fetch_attr(attrs, "api_key")

    with :ok <- ensure_credentials(site_url, api_key),
         {:ok, essentials} <- TickeraClient.get_event_essentials(site_url, api_key),
         {:ok, {start_date, end_date}} <- {:ok, resolve_tickera_window(attrs, essentials)},
         {:ok, credential_struct} <-
           set_tickera_credentials(%Event{}, site_url, api_key, start_date, end_date),
         credential_attrs <- credential_attrs_from_struct(credential_struct),
         event_attrs <- credential_attrs |> Map.merge(build_event_attrs(attrs, essentials)),
         {:ok, %Event{} = event} <- %Event{} |> Event.changeset(event_attrs) |> Repo.insert() do
      Logger.info("Created event #{event.id} for site #{site_url}")
      _ = persist_event_cache(event)
      invalidate_events_list_cache()
      {:ok, event}
    else
      {:error, :invalid_credentials} ->
        Logger.error("Failed to validate credentials for #{site_url}")
        {:error, "Invalid API key or site URL mismatch"}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}

      {:error, :encryption_failed} ->
        Logger.error("Unable to store credentials for #{site_url}: encryption failed")
        {:error, "Unable to store Tickera credentials"}

      {:error, reason} ->
        Logger.error("Unable to create event: #{inspect(reason)}")
        {:error, to_string(reason)}
    end
  end

  def create_event(_), do: {:error, "Invalid attributes"}

  @doc """
  Lists cached events along with their attendee counts, falling back to the
  database when the cache is cold.

  The result is cached for 15 minutes using the `"events:all"` key so
  successive dashboard loads stay under the 50ms target.

  ## Examples

      iex> Events.list_events()
      # Cache miss example – hits the database and stores the collection

      iex> CacheManager.put("events:all", [%Event{id: 1}], ttl: :timer.minutes(15))
      iex> Events.list_events()
      [%Event{id: 1}]
  """
  @spec list_events() :: [Event.t()]
  def list_events do
    case CacheManager.get(@events_list_cache_key) do
      {:ok, events} when is_list(events) ->
        Logger.debug(fn -> {"events cache hit", key: @events_list_cache_key, count: length(events)} end)
        events

      {:ok, nil} ->
        Logger.debug(fn -> {"events cache miss", key: @events_list_cache_key} end)
        fetch_and_cache_events()

      {:ok, other} ->
        Logger.debug(fn -> {"events cache miss due to unexpected payload", payload: inspect(other)} end)
        fetch_and_cache_events()

      {:error, reason} ->
        Logger.warning(fn -> {"events cache unavailable", reason: inspect(reason)} end)
        fetch_events_from_db()
    end
  end

  @doc """
  Retrieves an event by id using a cache-aside strategy.

  The event configuration is cached for one hour under the
  `"event_config:{event_id}"` key. Cache errors are logged and the database is
  queried directly when necessary.

  ## Examples

      iex> Events.get_event!(event.id)
      %Event{} # Cache miss – loads from the database and stores the entry

      iex> CacheManager.put("event_config:\#{event.id}", event, ttl: :timer.hours(1))
      iex> Events.get_event!(event.id)
      %Event{} # Cache hit – avoids a round trip to Postgres
  """
  @spec get_event!(integer()) :: Event.t()
  def get_event!(event_id) when is_integer(event_id) and event_id > 0 do
    cache_key = event_config_cache_key(event_id)

    case CacheManager.get(cache_key) do
      {:ok, %Event{} = event} ->
        Logger.debug(fn -> {"event cache hit", event_id: event_id} end)
        event

      {:ok, nil} ->
        Logger.debug(fn -> {"event cache miss", event_id: event_id} end)
        fetch_and_cache_event!(event_id)

      {:ok, other} ->
        Logger.debug(fn -> {"event cache miss due to unexpected payload", payload: inspect(other)} end)
        fetch_and_cache_event!(event_id)

      {:error, reason} ->
        Logger.warning(fn -> {"event cache unavailable", event_id: event_id, reason: inspect(reason)} end)
        Repo.get!(Event, event_id)
    end
  end

  def get_event!(event_id), do: Repo.get!(Event, event_id)

  @doc """
  Synchronizes attendees for the specified event and updates status timestamps.

  When `progress_callback` is supplied it is invoked for every fetched page with
  `(page, total_pages, count_for_page)`.

  ## Returns
    * `{:ok, message}` when syncing succeeds.
    * `{:error, reason}` if any step fails.
  """
  @spec sync_event(integer(), (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def sync_event(event_id, progress_callback \\ nil) do
    Logger.info("Starting attendee sync for event #{event_id}")

    case Repo.get(Event, event_id) do
      nil ->
        {:error, "Event not found"}

      %Event{} = event ->
        case can_sync_event?(event) do
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
                        count_message = resolve_synced_count(inserted_count, attendees, total_count)
                        invalidate_event_cache(event.id)
                        invalidate_events_list_cache()
                        invalidate_event_stats_cache(event.id)
                        invalidate_occupancy_cache(event.id)
                        stats = get_event_stats(event.id)
                        broadcast_event_stats(event.id, stats)
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
  Fetches an event and refreshes its `checked_in_count` statistic based on the
  number of attendees with a populated `checked_in_at` timestamp.

  ## Returns
    * `%Event{}` with updated `checked_in_count`.
  """
  @spec get_event_with_stats(integer()) :: Event.t()
  def get_event_with_stats(event_id) do
    event = get_event!(event_id)

    checked_in_count =
      from(a in Attendee,
        where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
        select: count(a.id)
      )
      |> Repo.one()

    case event |> Changeset.change(%{checked_in_count: checked_in_count}) |> Repo.update() do
      {:ok, updated} ->
        _ = persist_event_cache(updated)
        _ = invalidate_events_list_cache()
        updated

      {:error, changeset} ->
        Logger.error("Failed to update stats for event #{event_id}: #{inspect(changeset.errors)}")
        %{event | checked_in_count: checked_in_count}
    end
  end

  @doc ~S"""
  Returns cached roll-up statistics for an event including totals and
  occupancy percentage.

  Stats are cached for one minute using the `"stats:{event_id}"` key so
  repeated dashboard refreshes are served from memory.

  ## Examples

      iex> event_id = event.id
      iex> Events.get_event_stats(event_id)
      %{checked_in: 120, total_tickets: 500} # Cache miss – queries Postgres

      iex> CacheManager.put("stats:#{event_id}", %{checked_in: 5, total_tickets: 10}, ttl: :timer.minutes(1))
      iex> Events.get_event_stats(event_id)
      %{checked_in: 5, total_tickets: 10} # Cache hit – served from Cachex
  """

  @spec get_event_stats(integer()) :: map()
  def get_event_stats(event_id) when is_integer(event_id) and event_id > 0 do
    cache_key = stats_cache_key(event_id)

    case CacheManager.get(cache_key) do
      {:ok, %{} = stats} ->
        Logger.debug(fn -> {"stats cache hit", event_id: event_id} end)
        stats

      {:ok, nil} ->
        Logger.debug(fn -> {"stats cache miss", event_id: event_id} end)
        fetch_and_cache_event_stats(event_id)

      {:ok, other} ->
        Logger.debug(fn -> {"stats cache miss due to unexpected payload", payload: inspect(other)} end)
        fetch_and_cache_event_stats(event_id)

      {:error, reason} ->
        Logger.warning(fn -> {"stats cache unavailable", event_id: event_id, reason: inspect(reason)} end)
        compute_event_stats(event_id)
    end
  end

  def get_event_stats(_), do: @default_event_stats

  @doc ~S"""
  Updates the cached occupancy count when a guest enters or exits and
  broadcasts the new totals via PubSub.

  A cache miss triggers a recalculation from the attendee table so stale data
  never leaks into the occupancy dashboard.

  ## Examples

      iex> Events.update_occupancy(event.id, 1)
      {:ok, 101} # Cache miss – recalculates from the database

      iex> CacheManager.put("occupancy:event:#{event.id}", %{inside: 50}, ttl: :timer.seconds(10))
      iex> Events.update_occupancy(event.id, -1)
      {:ok, 49} # Cache hit – updates the cached snapshot
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
            Logger.debug(fn -> {"occupancy cache updated", event_id: event_id, inside: new_inside} end)

          {:error, reason} ->
            Logger.warning(fn -> {"occupancy cache update failed", event_id: event_id, reason: inspect(reason)} end)
        end

        broadcast_occupancy_update(event_id, new_inside)
        {:ok, new_inside}
    end
  rescue
    exception ->
      Logger.error("Occupancy update failed for event #{event_id}: #{Exception.message(exception)}")
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

      total_attendees = attendee_scope |> select([a], count(a.id)) |> Repo.one() |> normalize_count()

      checked_in =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at))
        |> select([a], count(a.id))
        |> Repo.one()
        |> normalize_count()

      pending = max(total_attendees - checked_in, 0)

      {currently_inside, occupancy_percentage, cached_entry_total, cached_exit_total} =
        case CacheManager.get_cached_occupancy(event_id) do
          {:ok, snapshot} ->
            {snapshot.inside, snapshot.percentage, snapshot.total_entries, snapshot.total_exits}

          {:error, _} ->
            fallback_inside =
              attendee_scope
              |> where([a], not is_nil(a.checked_in_at))
              |> where([a], is_nil(a.checked_out_at) or a.checked_out_at < a.checked_in_at)
              |> select([a], count(a.id))
              |> Repo.one()
              |> normalize_count()

            {fallback_inside, percentage(fallback_inside, total_attendees), nil, nil}
        end

      scans_today =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at) and a.checked_in_at >= ^start_of_day)
        |> select([a], count(a.id))
        |> Repo.one()
        |> normalize_count()

      per_entrance = fetch_per_entrance_stats(event_id)

      total_entries =
        cached_entry_total || Enum.reduce(per_entrance, 0, fn stat, acc -> acc + normalize_count(stat.entries) end)

      total_exits =
        cached_exit_total || Enum.reduce(per_entrance, 0, fn stat, acc -> acc + normalize_count(stat.exits) end)

      avg_session_seconds =
        attendee_scope
        |> where([a], not is_nil(a.checked_in_at) and not is_nil(a.checked_out_at))
        |> select([a], fragment("avg(extract(epoch from (? - ?)))", a.checked_out_at, a.checked_in_at))
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
        checked_in_percentage: percentage(checked_in, total_attendees),
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
        Logger.error("Failed to compute advanced stats for event #{event_id}: #{Exception.message(exception)}")
        default_advanced_stats()
    end
  end

  def get_event_advanced_stats(_), do: default_advanced_stats()

  @doc """
  Fetches live occupancy information for an event using the Tickera API,
  persists the latest statistics, and broadcasts the updated totals over PubSub.

  The API call is executed inside a supervised task so the caller is not blocked
  while the HTTP request completes.
  """
  @spec update_event_occupancy_live(integer()) :: {:ok, map()} | {:error, String.t()}
  def update_event_occupancy_live(event_id) when is_integer(event_id) do
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
        Logger.error("Live occupancy update failed for event #{event_id}: missing credentials")
        {:error, "MISSING_CREDENTIALS"}

      {:error, "MISSING_CREDENTIALS"} ->
        Logger.error("Live occupancy update failed for event #{event_id}: missing credentials")
        {:error, "MISSING_CREDENTIALS"}

      {:error, :decryption_failed} ->
        Logger.error("Live occupancy update failed for event #{event_id}: credential decryption failed")
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

  The payload contains the `event_id`, current `inside_count`, resolved
  `capacity`, and calculated occupancy `percentage`.
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
            {:occupancy_update, payload}
          )

          :ok
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

  @doc """
  Fetches Tickera ticket configurations for an event and upserts them locally.

  Returns the count of configurations inserted/updated or an error tuple when
  credentials are missing or a remote fetch fails.
  """
  @spec fetch_and_store_ticket_configs(integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def fetch_and_store_ticket_configs(event_id) when is_integer(event_id) do
    Repo.transaction(fn ->
      case Repo.get(Event, event_id) do
        nil ->
          Repo.rollback("EVENT_NOT_FOUND")

        %Event{} = event ->
          case ensure_event_credentials(event) do
            {:ok, _site_url, api_key} ->
              ticket_type_ids = load_ticket_type_ids(event.id)

              case persist_ticket_configs(event, ticket_type_ids, api_key) do
                {:ok, count} ->
                  case touch_last_config_sync(event.id) do
                    :ok ->
                      case touch_last_soft_sync(event.id) do
                        :ok -> count
                        {:error, reason} -> Repo.rollback(reason)
                      end

                    {:error, reason} -> Repo.rollback(reason)
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end

            {:error, :decryption_failed} ->
              Repo.rollback("CREDENTIAL_DECRYPTION_FAILED")

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, count} ->
        {:ok, count}

      {:error, reason}
      when reason in ["EVENT_NOT_FOUND", "MISSING_CREDENTIALS", "CONFIG_FETCH_FAILED", "CREDENTIAL_DECRYPTION_FAILED"] ->
        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "CONFIG_FETCH_FAILED"}
    end
  end

  def fetch_and_store_ticket_configs(_), do: {:error, "INVALID_EVENT"}

  @doc """
  Encrypts and persists Tickera credentials for the provided event.

  When called with a new `%Event{}` struct, the encrypted attributes are returned on
  the struct so they can be merged into a changeset prior to insert.
  """
  @spec set_tickera_credentials(
          Event.t(),
          String.t(),
          String.t(),
          DateTime.t() | NaiveDateTime.t() | Date.t() | String.t() | nil,
          DateTime.t() | NaiveDateTime.t() | Date.t() | String.t() | nil
        ) :: {:ok, Event.t()} | {:error, term()}
  def set_tickera_credentials(%Event{} = event, site_url, api_key, start_date, end_date)
      when is_binary(site_url) and is_binary(api_key) do
    start_datetime = coerce_event_datetime(start_date)
    end_datetime = coerce_event_datetime(end_date)

    with {:ok, encrypted} <- Crypto.encrypt(api_key),
         attrs <-
           %{
             tickera_site_url: String.trim(site_url),
             tickera_api_key_encrypted: encrypted,
             tickera_api_key_last4: derive_last4(api_key),
             tickera_start_date: start_datetime,
             tickera_end_date: end_datetime,
             status: "active"
           } do
      apply_credential_attrs(event, attrs)
    end
  end

  def set_tickera_credentials(_event, _site_url, _api_key, _start_date, _end_date),
    do: {:error, :invalid_credentials}

  defp refresh_event_window_from_tickera(%Event{} = event, api_key) when is_binary(api_key) do
    case TickeraClient.get_event_essentials(event.tickera_site_url, api_key) do
      {:ok, essentials} ->
        {start_dt, end_dt} = resolve_tickera_window(%{}, essentials)

        case persist_event_window(event, start_dt, end_dt) do
          {:ok, _updated} -> :ok
          :unchanged -> :ok
          {:error, reason} ->
            Logger.warning(fn ->
              {"event window update failed", event_id: event.id, reason: inspect(reason)}
            end)

            :error
        end

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
        {_field, nil}, acc -> acc
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
          _ = persist_event_cache(updated)
          _ = invalidate_events_list_cache()
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp same_datetime?(nil, nil), do: true
  defp same_datetime?(nil, _other), do: false
  defp same_datetime?(_other, nil), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.compare(DateTime.truncate(left, :second), DateTime.truncate(right, :second)) == :eq
  end

  defp same_datetime?(%NaiveDateTime{} = left, %NaiveDateTime{} = right) do
    NaiveDateTime.compare(NaiveDateTime.truncate(left, :second), NaiveDateTime.truncate(right, :second)) == :eq
  end

  defp same_datetime?(left, right), do: left == right

  @doc """
  Decrypts the stored Tickera API key for the event.
  """
  @spec get_tickera_api_key(Event.t() | nil) :: {:ok, String.t()} | {:error, :decryption_failed}
  def get_tickera_api_key(%Event{id: id, tickera_api_key_encrypted: encrypted}) when is_binary(encrypted) do
    case Crypto.decrypt(encrypted) do
      {:ok, api_key} -> {:ok, api_key}
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

  defp fetch_and_cache_event!(event_id) do
    event = Repo.get!(Event, event_id)
    _ = persist_event_cache(event)
    event
  end

  defp fetch_and_cache_event_stats(event_id) do
    stats = compute_event_stats(event_id)
    cache_event_stats(event_id, stats)
    stats
  end

  defp compute_event_stats(event_id) do
    base_stats = Attendees.get_event_stats(event_id)
    event = get_event!(event_id)

    total_tickets = normalize_non_neg_integer(event.total_tickets || Map.get(base_stats, :total, 0))
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
      Logger.error("Failed to compute stats for event #{event_id}: #{Exception.message(exception)}")
      @default_event_stats
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
        Logger.warning(fn -> {"occupancy cache read failed", event_id: event_id, reason: inspect(reason)} end)
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

  defp persist_event_cache(%Event{} = event) do
    case CacheManager.put(event_config_cache_key(event.id), event, ttl: @event_config_ttl) do
      {:ok, true} -> :ok
      {:error, reason} ->
        Logger.warning(fn -> {"event cache write failed", event_id: event.id, reason: inspect(reason)} end)
        :error
    end
  end

  defp cache_events_list(events) do
    case CacheManager.put(@events_list_cache_key, events, ttl: @events_list_ttl) do
      {:ok, true} -> :ok
      {:error, reason} ->
        Logger.warning(fn -> {"events cache write failed", reason: inspect(reason)} end)
        :error
    end
  end

  defp cache_event_stats(event_id, stats) do
    case CacheManager.put(stats_cache_key(event_id), stats, ttl: @stats_ttl) do
      {:ok, true} -> :ok
      {:error, reason} ->
        Logger.warning(fn -> {"stats cache write failed", event_id: event_id, reason: inspect(reason)} end)
        :error
    end
  end

  defp invalidate_event_cache(event_id) do
    case CacheManager.delete(event_config_cache_key(event_id)) do
      {:ok, _} ->
        Logger.debug(fn -> {"event cache invalidated", event_id: event_id} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn -> {"event cache invalidate failed", event_id: event_id, reason: inspect(reason)} end)
        :error
    end
  end

  defp invalidate_events_list_cache do
    case CacheManager.delete(@events_list_cache_key) do
      {:ok, _} ->
        Logger.debug(fn -> {"events list cache invalidated", key: @events_list_cache_key} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn -> {"events list cache invalidate failed", reason: inspect(reason)} end)
        :error
    end
  end

  defp invalidate_event_stats_cache(event_id) do
    case CacheManager.delete(stats_cache_key(event_id)) do
      {:ok, _} ->
        Logger.debug(fn -> {"stats cache invalidated", event_id: event_id} end)
        :ok

      {:error, reason} ->
        Logger.warning(fn -> {"stats cache invalidate failed", event_id: event_id, reason: inspect(reason)} end)
        :error
    end
  end

  defp invalidate_occupancy_cache(event_id) do
    pattern = occupancy_pattern(event_id)

    case CacheManager.invalidate_pattern(pattern) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning(fn -> {"occupancy pattern invalidation failed", event_id: event_id, reason: inspect(reason)} end)
        :error
    end

    case CacheManager.delete(occupancy_cache_key(event_id)) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning(fn -> {"occupancy cache delete failed", event_id: event_id, reason: inspect(reason)} end)
        :error
    end
  end

  defp broadcast_event_stats(event_id, stats) do
    Phoenix.PubSub.broadcast(
      FastCheck.PubSub,
      stats_topic(event_id),
      {:event_stats_updated, event_id, stats}
    )
  rescue
    exception ->
      Logger.error("Failed to broadcast stats for event #{event_id}: #{Exception.message(exception)}")
      {:error, :broadcast_failed}
  end

  defp event_config_cache_key(event_id), do: "event_config:#{event_id}"
  defp stats_cache_key(event_id), do: "stats:#{event_id}"
  defp occupancy_cache_key(event_id), do: "occupancy:event:#{event_id}"
  defp occupancy_pattern(event_id), do: "occupancy:event:#{event_id}:*"
  defp stats_topic(event_id), do: "event:#{event_id}:stats"

  defp ensure_credentials(site_url, api_key) when is_binary(site_url) and is_binary(api_key) do
    case TickeraClient.check_credentials(site_url, api_key) do
      {:ok, _resp} -> :ok
      {:error, _reason} -> {:error, :invalid_credentials}
    end
  end

  defp ensure_credentials(_site_url, _api_key), do: {:error, :invalid_credentials}

  defp ensure_event_credentials(%Event{tickera_site_url: site_url} = event) do
    cond do
      not present?(site_url) ->
        {:error, "MISSING_CREDENTIALS"}

      true ->
        case get_tickera_api_key(event) do
          {:ok, api_key} -> {:ok, site_url, api_key}
          {:error, :decryption_failed} -> {:error, :decryption_failed}
        end
    end
  end

  defp ensure_event_credentials(_), do: {:error, "MISSING_CREDENTIALS"}

  defp fetch_live_occupancy(site_url, api_key) do
    task = Task.async(fn -> TickeraClient.get_event_occupancy(site_url, api_key) end)

    try do
      Task.await(task, @occupancy_task_timeout)
    rescue
      e in Task.TimeoutError ->
        Task.shutdown(task, :brutal_kill)
        {:error, "TASK_TIMEOUT", Exception.message(e)}
    catch
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
        invalidate_event_cache(event_id)
        invalidate_events_list_cache()
        :ok
      _ -> {:error, :not_updated}
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

  defp normalize_occupancy_integer(value) when is_integer(value), do: value
  defp normalize_occupancy_integer(value) when is_float(value), do: trunc(value)
  defp normalize_occupancy_integer(_value), do: 0

  defp normalize_occupancy_float(value) when is_float(value), do: value
  defp normalize_occupancy_float(value) when is_integer(value), do: value / 1
  defp normalize_occupancy_float(_value), do: 0.0

  defp ensure_map(%{} = value), do: value
  defp ensure_map(_), do: %{}

  defp load_ticket_type_ids(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id and not is_nil(a.ticket_type_id),
      select: a.ticket_type_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.reduce([], fn raw, acc ->
      case normalize_ticket_type_id(raw) do
        nil ->
          Logger.debug("Skipping ticket type #{inspect(raw)} for event #{event_id}")
          acc

        id ->
          [id | acc]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ticket_type_id(value) when is_integer(value) and value > 0, do: value

  defp normalize_ticket_type_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        case Integer.parse(trimmed) do
          {number, _rest} when number > 0 -> number
          _ -> nil
        end
    end
  end

  defp normalize_ticket_type_id(%{} = value) do
    Map.get(value, :ticket_type_id)
    |> case do
      nil -> Map.get(value, "ticket_type_id")
      id -> id
    end
    |> case do
      nil -> nil
      id -> normalize_ticket_type_id(id)
    end
  end

  defp normalize_ticket_type_id(_), do: nil



    # Persist all ticket configs returned by Tickera for a given event.
  # Returns {:ok, count} on success or {:error, reason} on first failure.
  defp persist_ticket_configs(%Event{id: event_id} = _event, [], _api_key) do
    Logger.info("No ticket types discovered for event #{event_id}; skipping config sync")
    {:ok, 0}
  end

  defp persist_ticket_configs(%Event{id: event_id} = event, ticket_type_ids, api_key)
       when is_list(ticket_type_ids) do
    ticket_type_ids
    |> Enum.reduce_while({:ok, 0}, fn ticket_type_id, {:ok, count} ->
      case TickeraClient.get_ticket_config(
             event.tickera_site_url,
             api_key,
             ticket_type_id
           ) do
        {:ok, config} ->
          case upsert_ticket_config(event_id, ticket_type_id, config) do
            {:ok, _record} ->
              Logger.info("Stored ticket config #{ticket_type_id} for event #{event_id}")
              {:cont, {:ok, count + 1}}

            {:error, %Changeset{} = changeset} ->
              Logger.error(
                "Failed to upsert ticket config #{ticket_type_id} for event #{event_id}: #{inspect(changeset.errors)}"
              )

              {:halt, {:error, "CONFIG_FETCH_FAILED"}}
          end

        {:error, code, message} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{code} – #{message}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}

        {:error, reason} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{inspect(reason)}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end


  defp upsert_ticket_config(event_id, ticket_type_id, config) do
    attrs = build_config_attrs(config, event_id, ticket_type_id)

    %CheckInConfiguration{}
    |> CheckInConfiguration.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @config_replace_fields},
      conflict_target: [:event_id, :ticket_type_id],
      returning: true
    )
  end

  defp build_config_attrs(config, event_id, ticket_type_id) do
    config
    |> Map.take(@config_fields)
    |> Map.put(:event_id, event_id)
    |> Map.put(:ticket_type_id, ticket_type_id)
    |> normalize_config_dates()
    |> maybe_put_ticket_labels(config)
    |> maybe_put_check_in_window()
  end

  defp normalize_config_dates(attrs) do
    attrs
    |> Map.update(:check_in_window_start, nil, &normalize_date_value/1)
    |> Map.update(:check_in_window_end, nil, &normalize_date_value/1)
    |> Map.update(:last_checked_in_date, nil, &normalize_date_value/1)
  end

  defp maybe_put_ticket_labels(attrs, config) do
    attrs
    |> Map.put(:ticket_type, pick_ticket_label(config, [:ticket_type, :ticket_title, :ticket_name]))
    |> Map.put(:ticket_name, pick_ticket_label(config, [:ticket_name, :ticket_title, :ticket_type]))
  end

  defp pick_ticket_label(config, keys) do
    Enum.find_value(keys, fn key -> presence(Map.get(config, key)) end)
  end

  defp maybe_put_check_in_window(attrs) do
    start_date = Map.get(attrs, :check_in_window_start)
    end_date = Map.get(attrs, :check_in_window_end)

    case build_date_range(start_date, end_date) do
      nil -> attrs
      %Range{} = range -> Map.put(attrs, :check_in_window, range)
    end
  end

  defp build_date_range(nil, nil), do: nil

  defp build_date_range(start_date, end_date) do
    %Range{lower: start_date, upper: end_date, lower_inclusive: true, upper_inclusive: false}
  end

  defp normalize_date_value(nil), do: nil
  defp normalize_date_value(%Date{} = date), do: date
  defp normalize_date_value(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp normalize_date_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp normalize_date_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end

  defp normalize_date_value(_value), do: nil

  defp touch_last_config_sync(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in Event, where: e.id == ^event_id)
    |> Repo.update_all(set: [last_config_sync: now, updated_at: now])
    |> case do
      {1, _} ->
        invalidate_event_cache(event_id)
        invalidate_events_list_cache()
        :ok
      _ -> {:error, "EVENT_NOT_FOUND"}
    end
  end

  defp present?(value) when is_binary(value), do: presence(value) != nil
  defp present?(_), do: false

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

  defp derive_last4(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      start = max(String.length(trimmed) - 4, 0)
      String.slice(trimmed, start, 4)
    end
  end

  defp derive_last4(_), do: nil

  defp credential_attrs_from_struct(%Event{} = event) do
    event
    |> Map.take(@credential_fields)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp apply_credential_attrs(%Event{} = event, attrs) do
    case event.__meta__.state do
      :built ->
        {:ok, struct(event, attrs)}

      _ ->
        event
        |> Event.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, %Event{} = updated} ->
            invalidate_event_cache(updated.id)
            invalidate_events_list_cache()
            {:ok, updated}

          other ->
            other
        end
    end
  end

  defp build_event_attrs(attrs, essentials) do
    event_datetime =
      Map.get(essentials, "event_date_time") ||
        Map.get(essentials, :event_date_time)

    {event_date, event_time} = split_datetime(event_datetime)
    {tickera_start_date, tickera_end_date} = resolve_tickera_window(attrs, essentials)

    %{
      name:
        fetch_attr(attrs, "name") || Map.get(essentials, "event_name") ||
          Map.get(essentials, :event_name),
      entrance_name: fetch_attr(attrs, "entrance_name"),
      location: fetch_attr(attrs, "location"),
      total_tickets: Map.get(essentials, "total_tickets") || Map.get(essentials, :total_tickets),
      event_date: fetch_attr(attrs, "event_date") || event_date,
      event_time: fetch_attr(attrs, "event_time") || event_time,
      tickera_start_date: tickera_start_date,
      tickera_end_date: tickera_end_date,
      last_sync_at: fetch_attr(attrs, "last_sync_at"),
      last_soft_sync_at: fetch_attr(attrs, "last_soft_sync_at")
    }
  end

  defp split_datetime(%DateTime{} = datetime) do
    {DateTime.to_date(datetime), DateTime.to_time(datetime)}
  end

  defp split_datetime(%NaiveDateTime{} = datetime) do
    {NaiveDateTime.to_date(datetime), NaiveDateTime.to_time(datetime)}
  end

  defp split_datetime(%Date{} = date), do: {date, nil}
  defp split_datetime(%Time{} = time), do: {nil, time}

  defp split_datetime(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, datetime, _offset} ->
        {DateTime.to_date(datetime), DateTime.to_time(datetime)}

      _ ->
        case NaiveDateTime.from_iso8601(binary) do
          {:ok, naive} ->
            {NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive)}

          _ ->
            {nil, nil}
        end
    end
  end

  defp split_datetime(_), do: {nil, nil}

  defp resolve_tickera_window(attrs, essentials) do
    start_source =
      fetch_attr(attrs, "tickera_start_date") ||
        Map.get(essentials, "event_start_date") ||
        Map.get(essentials, :event_start_date) ||
        Map.get(essentials, "event_date_time") ||
        Map.get(essentials, :event_date_time)

    end_source =
      fetch_attr(attrs, "tickera_end_date") ||
        Map.get(essentials, "event_end_date") ||
        Map.get(essentials, :event_end_date)

    {
      coerce_event_datetime(start_source),
      coerce_event_datetime(end_source)
    }
  end

  defp coerce_event_datetime(nil), do: nil

  defp coerce_event_datetime(%DateTime{} = datetime) do
    shift_to_utc(datetime)
  rescue
    _ -> nil
  end

  defp coerce_event_datetime(%NaiveDateTime{} = datetime) do
    case DateTime.from_naive(datetime, "Etc/UTC") do
      {:ok, utc} -> DateTime.truncate(utc, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(%Time{} = time) do
    DateTime.new(Date.utc_today(), time, "Etc/UTC")
    |> case do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(trimmed) do
          shift_to_utc(datetime)
        else
          {:error, _} ->
            case NaiveDateTime.from_iso8601(trimmed) do
              {:ok, naive} -> coerce_event_datetime(naive)
              {:error, _} -> parse_unix_datetime(trimmed)
            end
        end
    end
  end

  defp coerce_event_datetime(value) when is_integer(value) do
    value
    |> DateTime.from_unix()
    |> case do
      {:ok, datetime} -> shift_to_utc(datetime)
      _ -> nil
    end
  end

  defp coerce_event_datetime(_value), do: nil

  defp parse_unix_datetime(trimmed) do
    case Integer.parse(trimmed) do
      {unix, ""} ->
        case DateTime.from_unix(unix) do
          {:ok, datetime} -> shift_to_utc(datetime)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp shift_to_utc(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone("Etc/UTC")
    |> case do
      {:ok, shifted} -> DateTime.truncate(shifted, :second)
      {:error, _} -> DateTime.truncate(datetime, :second)
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.get(attrs, key)

      true ->
        case safe_existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(attrs, atom_key)
        end
    end
  end

  defp fetch_attr(_attrs, _key), do: nil

  defp safe_existing_atom(key) do
    Map.get(@attr_atom_lookup, key)
  end

  defp mark_syncing(event) do
    now = DateTime.utc_now()

    case event
         |> Changeset.change(%{status: "syncing", sync_started_at: now, sync_completed_at: nil})
         |> Repo.update() do
      {:ok, _} ->
        case touch_last_sync(event.id) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("Unable to update last sync timestamp for event #{event.id}: #{inspect(reason)}")
        end
        invalidate_event_cache(event.id)
        invalidate_events_list_cache()
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Unable to mark event #{event.id} as syncing: #{inspect(changeset.errors)}"
        )
    end
  end

  defp finalize_sync(event) do
    now = DateTime.utc_now()

    case event
         |> Changeset.change(%{status: "active", sync_completed_at: now})
         |> Repo.update() do
      {:ok, _} ->
        invalidate_event_cache(event.id)
        invalidate_events_list_cache()
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Unable to finalize sync for event #{event.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp mark_error(event, reason) do
    case event
         |> Changeset.change(%{status: "error"})
         |> Repo.update() do
      {:ok, _} ->
        invalidate_event_cache(event.id)
        invalidate_events_list_cache()

      {:error, changeset} ->
        Logger.warning(
          "Unable to mark event #{event.id} as errored: #{inspect(changeset.errors)}"
        )
    end

    Logger.error("Sync failed for event #{event.id}: #{format_reason(reason)}")
  end

  defp wrap_progress_callback(nil), do: nil

  defp wrap_progress_callback(callback) when is_function(callback, 3) do
    fn page, total_pages, count ->
      Logger.debug("Sync progress page=#{page}/#{total_pages} count=#{count}")
      safe_callback(callback, page, total_pages, count)
    end
  end

  defp wrap_progress_callback(_), do: nil

  defp safe_callback(callback, page, total_pages, count) do
    try do
      callback.(page, total_pages, count)
    rescue
      exception ->
        Logger.warning("Progress callback error: #{Exception.message(exception)}")
    end
  end

  defp fetch_per_entrance_stats(event_id) do
    query =
      from(ci in CheckIn,
        where: ci.event_id == ^event_id,
        group_by: ci.entrance_name,
        select: %{
          entrance_name: fragment("coalesce(?, ?)", ci.entrance_name, ^"Unassigned"),
          entries: fragment("sum(case when lower(?) in ('entry','success') then 1 else 0 end)", ci.status),
          exits: fragment("sum(case when lower(?) in ('exit','checked_out') then 1 else 0 end)", ci.status),
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
      Logger.error("Failed to load entrance stats for event #{event_id}: #{Exception.message(exception)}")
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

  defp beginning_of_day_utc do
    date = Date.utc_today()

    with {:ok, naive} <- NaiveDateTime.new(date, ~T[00:00:00]),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      datetime
    else
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp normalize_count(nil), do: 0
  defp normalize_count(value) when is_integer(value), do: value
  defp normalize_count(value) when is_float(value), do: round(value)

  defp normalize_count(%Decimal{} = value) do
    value
    |> Decimal.to_float()
    |> round()
  rescue
    _ -> 0
  end

  defp update_sync_timestamp(event_id, attrs, updated_at) do
    updates =
      attrs
      |> Map.put(:updated_at, updated_at)
      |> Enum.to_list()

    case from(e in Event, where: e.id == ^event_id) |> Repo.update_all(set: updates) do
      {1, _} ->
        invalidate_event_cache(event_id)
        invalidate_events_list_cache()
        :ok

      _ ->
        {:error, :event_not_found}
    end
  end

  defp current_timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end



  defp normalize_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
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

  defp percentage(_part, total) when total <= 0, do: 0.0

  defp percentage(part, total) do
    part_float = normalize_float(part)
    total_float = normalize_float(total)

    if total_float <= 0 do
      0.0
    else
      Float.round(part_float / total_float * 100, 2)
    end
  end

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

  defp format_reason({:error, reason}), do: format_reason(reason)
  defp format_reason(%Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp resolve_synced_count(inserted_count, attendees, total_count) do
    cond do
      is_integer(inserted_count) ->
        inserted_count

      is_map(inserted_count) and Map.has_key?(inserted_count, :count) ->
        Map.get(inserted_count, :count)

      is_map(inserted_count) and Map.has_key?(inserted_count, "count") ->
        Map.get(inserted_count, "count")

      is_map(inserted_count) and Map.has_key?(inserted_count, :inserted) ->
        Map.get(inserted_count, :inserted)

      is_map(inserted_count) and Map.has_key?(inserted_count, "inserted") ->
        Map.get(inserted_count, "inserted")

      is_list(inserted_count) ->
        length(inserted_count)

      is_integer(total_count) ->
        total_count

      true ->
        length(attendees)
    end
  end

  defp normalize_reference_datetime(nil), do: DateTime.utc_now() |> DateTime.to_naive()

  defp normalize_reference_datetime(%DateTime{} = datetime) do
    DateTime.to_naive(datetime)
  rescue
    _ -> normalize_reference_datetime(nil)
  end

  defp normalize_reference_datetime(%NaiveDateTime{} = datetime), do: datetime
  defp normalize_reference_datetime(_), do: normalize_reference_datetime(nil)

  defp normalize_event_datetime(nil), do: nil

  defp normalize_event_datetime(%NaiveDateTime{} = datetime), do: datetime

  defp normalize_event_datetime(%DateTime{} = datetime) do
    DateTime.to_naive(datetime)
  rescue
    _ -> nil
  end

  defp normalize_event_datetime(_), do: nil

  defp grace_period_end(nil), do: nil

  defp grace_period_end(%NaiveDateTime{} = end_time) do
    grace_days = event_post_grace_days()

    if grace_days > 0 do
      NaiveDateTime.add(end_time, grace_days * @seconds_per_day, :second)
    else
      end_time
    end
  end

  defp event_post_grace_days do
    Application.get_env(:fastcheck, :event_post_grace_days, 0)
    |> normalize_non_neg_integer()
  end
end
