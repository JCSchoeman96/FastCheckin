defmodule FastCheck.Attendees do
  @moduledoc """
  Context responsible for attendee persistence, ticket scanning, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Repo
  alias Phoenix.PubSub
  alias FastCheck.{
    Attendees.Attendee,
    Attendees.CheckIn,
    Attendees.CheckInSession,
    Cache.CacheManager,
    Events,
    TickeraClient
  }

  @ticket_code_min 3
  @ticket_code_max 100
  @ticket_code_pattern ~r/^[A-Za-z0-9\-\._]+$/
  @entrance_name_pattern ~r/^[A-Za-z0-9\s\-\._]+$/
  @cache_name :fastcheck_cache
  @default_occupancy_cache_ttl :timer.seconds(2)
  @attendee_cache_namespace "attendee"
  @attendee_cache_hit_ttl :infinity
  @attendee_cache_miss_ttl :timer.minutes(1)
  @attendee_cache_not_found :attendee_not_found
  @attendee_id_cache_prefix "attendee:id"
  @attendee_id_cache_ttl :timer.minutes(30)
  @event_attendees_cache_prefix "attendees:event"
  @event_attendees_cache_ttl :timer.minutes(5)

  @doc """
  Bulk inserts attendees for the provided event.

  Returns `{:ok, count}` where `count` is the number of new attendees stored.
  """
  @spec create_bulk(integer(), list()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def create_bulk(event_id, attendees_data) when is_integer(event_id) and is_list(attendees_data) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      attendees_data
      |> Enum.map(fn ticket ->
        parsed = TickeraClient.parse_attendee(ticket)

        allowed =
          parsed
          |> Map.get(:allowed_checkins)
          |> normalize_allowed_checkins()

        parsed
        |> Map.put(:event_id, event_id)
        |> Map.put_new(:checkins_remaining, allowed)
        |> Map.put(:allowed_checkins, allowed)
        |> Map.put_new(:daily_scan_count, 0)
        |> Map.put_new(:weekly_scan_count, 0)
        |> Map.put_new(:monthly_scan_count, 0)
        |> Map.put_new(:is_currently_inside, false)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)
      |> Enum.reject(fn row -> is_nil(Map.get(row, :ticket_code)) end)

    try do
      case entries do
        [] ->
          Logger.info("No attendees to insert for event #{event_id}")
          {:ok, 0}

        _ ->
          {count, _} = Repo.insert_all(Attendee, entries, on_conflict: :nothing)
          Logger.info("Inserted #{count} attendees for event #{event_id}")
          {:ok, count}
      end
    rescue
      exception ->
        Logger.error("Bulk attendee insert failed for event #{event_id}: #{Exception.message(exception)}")
        {:error, "Failed to store attendees"}
    end
  end

  def create_bulk(_event_id, _data), do: {:error, "Invalid attendee data"}

  @doc """
  Processes a check-in attempt for a ticket code.

  Successful scans now invalidate the attendee, stats, and occupancy caches so
  dashboards refresh immediately. Returns `{:ok, attendee, "SUCCESS"}` when the
  scan is valid, otherwise `{:error, code, message}` describing the failure.
  """
  @spec check_in(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in(event_id, ticket_code, entrance_name \\ "Main", operator_name \\ nil)

  def check_in(event_id, ticket_code, entrance_name, operator_name)
      when is_integer(event_id) and is_binary(ticket_code) and
             is_binary(entrance_name) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, sanitized_code} <- validate_ticket_code(ticket_code),
         {:ok, sanitized_entrance} <- validate_entrance_name(entrance_name) do
      query =
        from(a in Attendee,
          where: a.event_id == ^event_id and a.ticket_code == ^sanitized_code,
          lock: "FOR UPDATE NOWAIT"
        )

      try do
        Repo.transaction(fn ->
          case Repo.one(query) do
            nil ->
              Logger.warning("Invalid ticket #{sanitized_code} for event #{event_id}")
              record_check_in(%{ticket_code: sanitized_code}, event_id, "invalid", sanitized_entrance, operator_name)
              broadcast_event_stats_async(event_id)
              {:error, "INVALID", "Ticket not found"}

            %Attendee{} = attendee ->
              remaining = attendee.checkins_remaining || attendee.allowed_checkins || 0

              cond do
                attendee.checked_in_at && remaining <= 0 ->
                  Logger.warning("Duplicate ticket #{sanitized_code} for event #{event_id}")
                  record_check_in(attendee, event_id, "duplicate", sanitized_entrance, operator_name)
                  broadcast_event_stats_async(event_id)
                  {:error, "DUPLICATE", "Already checked in at #{format_datetime(attendee.checked_in_at)}"}

                true ->
                  now = DateTime.utc_now() |> DateTime.truncate(:second)
                  new_remaining = max(remaining - 1, 0)

                  attrs = %{
                    checked_in_at: now,
                    last_checked_in_at: now,
                    checkins_remaining: new_remaining
                  }

                  case Attendee.changeset(attendee, attrs) |> Repo.update() do
                    {:ok, updated} ->
                      invalidate_check_in_caches(updated, event_id, sanitized_code)
                      refresh_event_occupancy(event_id)
                      record_check_in(updated, event_id, "success", sanitized_entrance, operator_name)
                      broadcast_event_stats_async(event_id)
                      log_check_in(:success, %{
                        event_id: event_id,
                        attendee_id: updated.id,
                        entrance_name: sanitized_entrance,
                        response_time_ms: elapsed_time_ms(started_at),
                        ticket_code: sanitized_code,
                        remaining_checkins: new_remaining,
                        operator_name: operator_name
                      })
                      {:ok, updated, "SUCCESS"}

                    {:error, changeset} ->
                      log_check_in(:update_failed, %{
                        event_id: event_id,
                        attendee_id: attendee.id,
                        entrance_name: sanitized_entrance,
                        response_time_ms: elapsed_time_ms(started_at),
                        ticket_code: sanitized_code,
                        error: inspect(changeset.errors)
                      })
                      Repo.rollback({:changeset, "Failed to update attendee"})
                  end
              end
          end
        end)
        |> case do
          {:ok, result} -> result
          {:error, {:changeset, message}} -> {:error, "ERROR", message}
          {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
            {:error, "TICKET_IN_USE_ELSEWHERE", "Ticket is currently being processed"}
          {:error, reason} ->
            log_check_in(:transaction_failed, %{
              event_id: event_id,
              attendee_id: nil,
              entrance_name: sanitized_entrance,
              response_time_ms: elapsed_time_ms(started_at),
              ticket_code: sanitized_code,
              error: inspect(reason)
            })
            {:error, "ERROR", "Unable to process check-in"}
        end
      rescue
        exception ->
          log_check_in(:exception, %{
            event_id: event_id,
            attendee_id: nil,
            entrance_name: sanitized_entrance,
            response_time_ms: elapsed_time_ms(started_at),
            ticket_code: sanitized_code,
            error: Exception.message(exception)
          })
          {:error, "ERROR", "Unexpected error"}
      end
    else
      {:error, {:invalid_ticket_code, message}} ->
        Logger.warning("Check-in rejected: #{message}")
        {:error, "INVALID_CODE", message}

      {:error, {:invalid_entrance_name, message}} ->
        Logger.warning("Check-in rejected: #{message}")
        {:error, "INVALID_CODE", message}
    end
  end

  def check_in(_, _, _, _), do: {:error, "INVALID_CODE", "Invalid ticket code"}

  @doc """
  Performs an advanced check-in that tracks the richer scan metadata and
  updates the attendee counters atomically.

  Returns `{:ok, attendee, "SUCCESS"}` on success or
  `{:error, code, message}` on validation/database failures.
  """
  @spec check_in_advanced(integer(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in_advanced(event_id, ticket_code, check_in_type, entrance_name, operator_name \\ nil)

  def check_in_advanced(event_id, ticket_code, check_in_type, entrance_name, operator_name)
      when is_integer(event_id) and is_binary(ticket_code) and
             is_binary(check_in_type) and is_binary(entrance_name) do
    sanitized_code = ticket_code |> String.trim()
    sanitized_type = check_in_type |> String.trim()
    sanitized_entrance = entrance_name |> String.trim()

    cond do
      sanitized_code == "" ->
        Logger.warning("Advanced check-in rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_type == "" ->
        Logger.warning("Advanced check-in rejected: blank check-in type")
        {:error, "INVALID_TYPE", "Check-in type is required"}

      sanitized_entrance == "" ->
        Logger.warning("Advanced check-in rejected: blank entrance name")
        {:error, "INVALID_ENTRANCE", "Entrance name is required"}

      true ->
        do_advanced_check_in(
          event_id,
          sanitized_code,
          sanitized_type,
          sanitized_entrance,
          operator_name
        )
    end
  end

  def check_in_advanced(_, _, _, _, _),
    do: {:error, "INVALID_TICKET", "Unable to process advanced check-in"}

  @doc """
  Checks an attendee out of the venue and records the session history.
  """
  @spec check_out(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_out(event_id, ticket_code, entrance_name, operator_name \\ nil)

  def check_out(event_id, ticket_code, entrance_name, operator_name)
      when is_integer(event_id) and is_binary(ticket_code) and
             is_binary(entrance_name) do
    sanitized_code = String.trim(ticket_code)
    sanitized_entrance = String.trim(entrance_name)

    cond do
      sanitized_code == "" ->
        Logger.warning("Check-out rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_entrance == "" ->
        Logger.warning("Check-out rejected: blank entrance name")
        {:error, "INVALID_ENTRANCE", "Entrance name is required"}

      true ->
        do_check_out(event_id, sanitized_code, sanitized_entrance, operator_name)
    end
  end

  def check_out(_, _, _, _), do: {:error, "INVALID_TICKET", "Unable to process check-out"}

  @doc """
  Resets the scan counters for a specific attendee.
  """
  @spec reset_scan_counters(integer(), String.t()) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def reset_scan_counters(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    sanitized_code = String.trim(ticket_code)

    if sanitized_code == "" do
      Logger.warning("Reset scan counters rejected: blank ticket code")
      {:error, "INVALID_TICKET", "Ticket code is required"}
    else
      do_reset_scan_counters(event_id, sanitized_code)
    end
  end

  def reset_scan_counters(_, _),
    do: {:error, "INVALID_TICKET", "Unable to reset scan counters"}

  @doc """
  Marks a manual entry after validating the ticket and increments counters.
  """
  @spec mark_manual_entry(integer(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def mark_manual_entry(event_id, ticket_code, entrance_name, operator_name \\ nil, notes \\ nil)

  def mark_manual_entry(event_id, ticket_code, entrance_name, operator_name, notes)
      when is_integer(event_id) and is_binary(ticket_code) and
             is_binary(entrance_name) do
    sanitized_code = String.trim(ticket_code)
    sanitized_entrance = String.trim(entrance_name)

    cond do
      sanitized_code == "" ->
        Logger.warning("Manual entry rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_entrance == "" ->
        Logger.warning("Manual entry rejected: blank entrance name")
        {:error, "INVALID_ENTRANCE", "Entrance name is required"}

      true ->
        do_manual_entry(event_id, sanitized_code, sanitized_entrance, operator_name, notes)
    end
  end

  def mark_manual_entry(_, _, _, _, _),
    do: {:error, "INVALID_TICKET", "Unable to mark manual entry"}

  @doc """
  Computes the real-time occupancy breakdown for a given event.
  """
  @spec get_occupancy_breakdown(integer()) :: %{optional(atom()) => integer() | float()}
  def get_occupancy_breakdown(event_id) when is_integer(event_id) do
    cache_key = occupancy_cache_key(event_id)

    with {:ok, cached} <- fetch_cached_occupancy_breakdown(cache_key) do
      cached
    else
      _ ->
        breakdown = compute_occupancy_breakdown(event_id)
        persist_occupancy_cache(cache_key, breakdown)
        breakdown
    end
  rescue
    exception ->
      Logger.error(
        "Failed to compute occupancy breakdown for event #{event_id}: #{Exception.message(exception)}"
      )

      default_occupancy_breakdown()
  end

  def get_occupancy_breakdown(_), do: default_occupancy_breakdown()

  defp compute_occupancy_breakdown(event_id) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id,
        select: %{
          total: count(a.id),
          checked_in: fragment("sum(case when ? IS NOT NULL then 1 else 0 end)", a.checked_in_at),
          checked_out: fragment("sum(case when ? IS NOT NULL then 1 else 0 end)", a.checked_out_at),
          currently_inside:
            fragment("sum(case when ? = true then 1 else 0 end)", a.is_currently_inside)
        }
      )

    case Repo.one(query) do
      nil ->
        default_occupancy_breakdown()

      %{total: total, checked_in: checked_in, checked_out: checked_out, currently_inside: inside} ->
        total_int = normalize_count(total)
        checked_in_int = normalize_count(checked_in)
        checked_out_int = normalize_count(checked_out)
        inside_int = normalize_count(inside)

        percentage =
          if total_int > 0 do
            Float.round(inside_int / total_int * 100, 2)
          else
            0.0
          end

        %{
          total: total_int,
          checked_in: checked_in_int,
          checked_out: checked_out_int,
          currently_inside: inside_int,
          occupancy_percentage: percentage,
          pending: max(total_int - checked_in_int, 0)
        }
    end
  end

  defp fetch_cached_occupancy_breakdown(cache_key) do
    if occupancy_cache_available?() do
      case Cachex.get(@cache_name, cache_key) do
        {:ok, %{} = cached} -> {:ok, cached}
        {:ok, nil} -> :miss
        {:error, reason} ->
          Logger.warning("Occupancy cache lookup failed for #{cache_key}: #{inspect(reason)}")
          :miss
      end
    else
      :miss
    end
  rescue
    exception ->
      Logger.warning("Occupancy cache lookup failed for #{cache_key}: #{Exception.message(exception)}")
      :miss
  end

  defp persist_occupancy_cache(cache_key, value) do
    if not occupancy_cache_available?() do
      :ok
    else
      ttl = occupancy_cache_ttl()
      :ok = Cachex.put(@cache_name, cache_key, value, ttl: ttl)
    end
  rescue
    exception ->
      Logger.warning("Unable to persist occupancy cache #{cache_key}: #{Exception.message(exception)}")
      :ok
  end

  defp occupancy_cache_key(event_id), do: "occupancy:event:#{event_id}:breakdown"

  defp occupancy_cache_ttl do
    Application.get_env(:fastcheck, :occupancy_breakdown_cache_ttl, @default_occupancy_cache_ttl)
  end

  defp occupancy_cache_available? do
    Application.get_env(:fastcheck, :cache_enabled, true) and
      match?(pid when is_pid(pid), Process.whereis(@cache_name))
  end

  defp default_occupancy_breakdown do
    %{total: 0, checked_in: 0, checked_out: 0, currently_inside: 0, occupancy_percentage: 0.0, pending: 0}
  end

  defp fetch_attendee_with_cache(event_id, ticket_code, cache_key) do
    case Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code) do
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
        Logger.warning("Unable to store attendee cache entry for #{cache_key}: #{inspect(reason)}")
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
        Logger.warning("Unable to store attendee id cache entry for #{cache_key}: #{inspect(reason)}")
        :error
    end
  rescue
    exception ->
      Logger.warning("Attendee id cache write raised for #{cache_key}: #{Exception.message(exception)}")
      :error
  end

  @doc """
  Fetches a single attendee by ticket code within an event, leveraging the
  attendee cache for faster lookups.
  """
  @spec get_attendee_by_ticket_code(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee_by_ticket_code(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    cache_key =
      attendee_cache_key(event_id, ticket_code)

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

      {:error, reason} ->
        Logger.warning("Attendee cache lookup failed for #{cache_key}: #{inspect(reason)}")
        fetch_attendee_with_cache(event_id, ticket_code, cache_key)
    end
  rescue
    exception ->
      Logger.warning("Attendee cache lookup raised for #{cache_key}: #{Exception.message(exception)}")
      fetch_attendee_with_cache(event_id, ticket_code, cache_key)
  end

  def get_attendee_by_ticket_code(_, _), do: nil

  @spec get_attendee(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    get_attendee_by_ticket_code(event_id, ticket_code)
  end

  def get_attendee(_, _), do: nil

  @doc """
  Fetches a single attendee by id using a dedicated cache entry.
  """
  @spec get_attendee!(integer()) :: Attendee.t()
  def get_attendee!(attendee_id) when is_integer(attendee_id) and attendee_id > 0 do
    cache_key =
      attendee_id_cache_key(attendee_id)

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
      Logger.warning("Attendee id cache lookup raised for #{cache_key}: #{Exception.message(exception)}")
      Repo.get!(Attendee, attendee_id)
  end

  def get_attendee!(attendee_id), do: Repo.get!(Attendee, attendee_id)

  @doc """
  Removes the cached attendee lookup by id so future reads hit the database.
  """
  @spec delete_attendee_id_cache(integer()) :: :ok | :error
  def delete_attendee_id_cache(attendee_id) when is_integer(attendee_id) and attendee_id > 0 do
    cache_key =
      attendee_id_cache_key(attendee_id)

    case CacheManager.delete(cache_key) do
      {:ok, true} ->
        Logger.debug("Deleted attendee id cache entry for #{cache_key}")
        :ok

      {:error, :cache_unavailable} ->
        Logger.debug("Cache unavailable when deleting #{cache_key}, skipping invalidation")
        :ok

      {:error, reason} ->
        Logger.warning("Unable to delete attendee id cache entry for #{cache_key}: #{inspect(reason)}")
        :error
    end
  rescue
    exception ->
      Logger.warning("Attendee id cache delete raised for #{cache_key}: #{Exception.message(exception)}")
      :error
  end

  def delete_attendee_id_cache(_), do: :ok

  defp invalidate_check_in_caches(%Attendee{id: attendee_id}, event_id, ticket_code)
       when is_integer(event_id) and is_binary(ticket_code) do
    delete_attendee_cache_entry(event_id, ticket_code)
    delete_attendee_id_cache(attendee_id)
    delete_cache_entry("attendees:event:#{event_id}", "event attendees cache")
    delete_cache_entry("stats:#{event_id}", "event stats cache")
    purge_local_occupancy_breakdown(event_id)
    :ok
  end

  defp invalidate_check_in_caches(_, _, _), do: :ok

  defp delete_attendee_cache_entry(event_id, ticket_code) do
    case CacheManager.delete_attendee(event_id, ticket_code) do
      {:ok, true} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to delete attendee cache entry for event #{event_id} ticket #{ticket_code}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    exception ->
      Logger.warning(
        "Attendee cache delete raised for event #{event_id} ticket #{ticket_code}: #{Exception.message(exception)}"
      )

      :error
  end

  defp delete_cache_entry(key, description) do
    case CacheManager.delete(key) do
      {:ok, true} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete #{description} (#{key}): #{inspect(reason)}")
        :error
    end
  rescue
    exception ->
      Logger.warning("Cache delete raised for #{description} (#{key}): #{Exception.message(exception)}")
      :error
  end

  defp purge_local_occupancy_breakdown(event_id) do
    cache_key = occupancy_cache_key(event_id)

    if occupancy_cache_available?() do
      case Cachex.del(@cache_name, cache_key) do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning(
            "Failed to purge occupancy breakdown cache for event #{event_id} (#{cache_key}): #{inspect(reason)}"
          )

          :error
      end
    else
      :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Occupancy breakdown cache purge raised for event #{event_id}: #{Exception.message(exception)}"
      )

      :error
  end

  defp refresh_event_occupancy(event_id) when is_integer(event_id) do
    case Events.update_occupancy(event_id, 1) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Unable to refresh occupancy for event #{event_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Occupancy refresh raised for event #{event_id}: #{Exception.message(exception)}")
      :ok
  end

  defp refresh_event_occupancy(_), do: :ok

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.
  """
  @spec list_event_attendees(integer()) :: [Attendee.t()]
  def list_event_attendees(event_id) when is_integer(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id,
      order_by: [desc: a.checked_in_at]
    )
    |> Repo.all()
  end

  def list_event_attendees(_), do: []

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
        {:ok, nil} -> fetch_and_cache_attendees_by_event(event_id, cache_key)
        {:ok, attendees} when is_list(attendees) -> attendees
        {:error, reason} ->
          Logger.warning("Attendee list cache read failed for event #{event_id}: #{inspect(reason)}")
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
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to delete attendees cache for event #{event_id}: #{inspect(reason)}")
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

  defp fetch_and_cache_attendees_by_event(event_id, cache_key) do
    attendees = list_event_attendees(event_id)

    case CacheManager.put(cache_key, attendees, ttl: @event_attendees_cache_ttl) do
      {:ok, true} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to store attendees cache for event #{event_id}: #{inspect(reason)}")
        :error
    end

    attendees
  end

  defp attendees_by_event_cache_key(event_id), do: "#{@event_attendees_cache_prefix}:#{event_id}"

  @doc """
  Computes aggregate statistics for an event's attendees.
  """
  @spec get_event_stats(integer()) :: %{total: integer(), checked_in: integer(), pending: integer(), percentage: float()}
  def get_event_stats(event_id) when is_integer(event_id) do
    try do
      total =
        from(a in Attendee,
          where: a.event_id == ^event_id,
          select: count(a.id)
        )
        |> Repo.one()
        |> Kernel.||(0)

      checked_in =
        from(a in Attendee,
          where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
          select: count(a.id)
        )
        |> Repo.one()
        |> Kernel.||(0)

      pending = max(total - checked_in, 0)
      percentage = if total == 0, do: 0.0, else: Float.round(checked_in / total * 100, 2)

      %{total: total, checked_in: checked_in, pending: pending, percentage: percentage}
    rescue
      exception ->
        Logger.error("Failed to compute stats for event #{event_id}: #{Exception.message(exception)}")
        %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}
    end
  end

  def get_event_stats(_), do: %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}

  @doc """
  Performs a debounced attendee search scoped to a single event.

  Supports case-insensitive matches across first/last name, email, and
  ticket code fields.
  """
  @spec search_event_attendees(integer(), String.t() | nil, pos_integer()) :: [Attendee.t()]
  def search_event_attendees(event_id, query, limit \\ 20)

  def search_event_attendees(event_id, query, limit) when is_integer(event_id) do
    trimmed = sanitize_query(query)

    if trimmed == "" do
      []
    else
      safe_limit = normalize_limit(limit)
      pattern = "%#{escape_like(trimmed)}%"

      from(a in Attendee,
        where: a.event_id == ^event_id,
        where:
          ilike(a.first_name, ^pattern) or
            ilike(a.last_name, ^pattern) or
            ilike(a.email, ^pattern) or
            ilike(a.ticket_code, ^pattern),
        order_by: [asc: a.last_name, asc: a.first_name, asc: a.id],
        limit: ^safe_limit
      )
      |> Repo.all()
    end
  rescue
    exception ->
      Logger.error("Attendee search failed for event #{event_id}: #{Exception.message(exception)}")
      []
  end

  def search_event_attendees(_, _, _), do: []

  defp do_advanced_check_in(event_id, ticket_code, check_in_type, entrance_name, operator_name) do
    Logger.info(
      "Advanced check-in start event=#{event_id} ticket=#{ticket_code} type=#{check_in_type} entrance=#{entrance_name}"
    )

    operator = maybe_trim(operator_name)

    Repo.transaction(fn ->
      with {:ok, attendee} <- fetch_attendee_for_update(event_id, ticket_code),
           {attendee_with_config, _config} <- attach_ticket_config(event_id, attendee),
           :ok <- ensure_can_check_in(attendee_with_config) do
        attrs = build_check_in_attributes(attendee_with_config, entrance_name)

        case Attendee.changeset(attendee_with_config, attrs) |> Repo.update() do
          {:ok, updated} ->
            with {:ok, _session} <- upsert_active_session(updated, entrance_name) do
              normalized_type = String.downcase(check_in_type)

              record_check_in(
                updated,
                event_id,
                normalized_type,
                entrance_name,
                operator
              )

              maybe_increment_occupancy(event_id, normalized_type)
              %{attendee: updated, message: "SUCCESS"}
            else
              {:error, session_reason} -> Repo.rollback(session_reason)
            end

          {:error, changeset} ->
            Logger.error("Advanced check-in update failed for #{ticket_code}: #{inspect(changeset.errors)}")
            Repo.rollback({"UPDATE_FAILED", "Unable to process advanced check-in"})
        end
      else
        {:error, code, message} ->
          Logger.warning("Advanced check-in aborted for #{ticket_code}: #{code}")
          Repo.rollback({code, message})
      end
    end)
    |> handle_session_transaction(event_id, true)
  end

  defp do_check_out(event_id, ticket_code, entrance_name, operator_name) do
    Logger.info(
      "Check-out start event=#{event_id} ticket=#{ticket_code} entrance=#{entrance_name} operator=#{operator_name || "n/a"}"
    )

    operator = maybe_trim(operator_name)

    Repo.transaction(fn ->
      with {:ok, attendee} <- fetch_attendee_for_update(event_id, ticket_code),
           :ok <- ensure_can_check_out(attendee) do
        now = current_timestamp()

        attrs = %{
          checked_out_at: now,
          is_currently_inside: false
        }

        case Attendee.changeset(attendee, attrs) |> Repo.update() do
          {:ok, updated} ->
            with {:ok, _session} <- close_active_session(updated, entrance_name, now) do
              record_check_in(updated, event_id, "checked_out", entrance_name, operator)
              maybe_increment_occupancy(event_id, "exit")
              %{attendee: updated, message: "CHECKED_OUT"}
            else
              {:error, session_reason} -> Repo.rollback(session_reason)
            end

          {:error, changeset} ->
            Logger.error("Check-out update failed for #{ticket_code}: #{inspect(changeset.errors)}")
            Repo.rollback({"UPDATE_FAILED", "Unable to complete check-out"})
        end
      else
        {:error, code, message} ->
          Logger.warning("Check-out aborted for #{ticket_code}: #{code}")
          Repo.rollback({code, message})
      end
    end)
    |> handle_session_transaction(event_id, true)
  end

  defp do_reset_scan_counters(event_id, ticket_code) do
    Repo.transaction(fn ->
      with {:ok, attendee} <- fetch_attendee_for_update(event_id, ticket_code) do
        attrs = %{
          daily_scan_count: 0,
          weekly_scan_count: 0,
          monthly_scan_count: 0,
          last_checked_in_date: nil
        }

        case Attendee.changeset(attendee, attrs) |> Repo.update() do
          {:ok, updated} ->
            %{attendee: updated, message: "SCAN_COUNTERS_RESET"}

          {:error, changeset} ->
            Logger.error("Reset scan counters failed for #{ticket_code}: #{inspect(changeset.errors)}")
            Repo.rollback({"UPDATE_FAILED", "Unable to reset scan counters"})
        end
      else
        {:error, code, message} ->
          Logger.warning("Reset scan counters aborted for #{ticket_code}: #{code}")
          Repo.rollback({code, message})
      end
    end)
    |> handle_session_transaction(event_id, false)
  end

  defp do_manual_entry(event_id, ticket_code, entrance_name, operator_name, notes) do
    Logger.info(
      "Manual entry start event=#{event_id} ticket=#{ticket_code} entrance=#{entrance_name} operator=#{operator_name || "n/a"}"
    )

    operator = maybe_trim(operator_name)
    _notes = maybe_trim(notes)

    Repo.transaction(fn ->
      with {:ok, attendee} <- fetch_attendee_for_update(event_id, ticket_code),
           {attendee_with_config, _} <- attach_ticket_config(event_id, attendee),
           :ok <- ensure_can_check_in(attendee_with_config) do
        attrs = build_check_in_attributes(attendee_with_config, entrance_name)

        case Attendee.changeset(attendee_with_config, attrs) |> Repo.update() do
          {:ok, updated} ->
            with {:ok, _session} <- upsert_active_session(updated, entrance_name) do
              record_check_in(updated, event_id, "manual", entrance_name, operator)
              maybe_increment_occupancy(event_id, "entry")
              %{attendee: updated, message: "MANUAL_ENTRY_RECORDED"}
            else
              {:error, session_reason} -> Repo.rollback(session_reason)
            end

          {:error, changeset} ->
            Logger.error("Manual entry update failed for #{ticket_code}: #{inspect(changeset.errors)}")
            Repo.rollback({"UPDATE_FAILED", "Unable to mark manual entry"})
        end
      else
        {:error, code, message} ->
          Logger.warning("Manual entry aborted for #{ticket_code}: #{code}")
          Repo.rollback({code, message})
      end
    end)
    |> handle_session_transaction(event_id, true)
  end

  defp sanitize_query(nil), do: ""
  defp sanitize_query(query) when is_binary(query), do: String.trim(query)
  defp sanitize_query(query), do: query |> to_string() |> String.trim()

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 50)
  defp normalize_limit(_limit), do: 20

  defp escape_like(term) when is_binary(term) do
    term
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp escape_like(term), do: term

  defp fetch_attendee_for_update(event_id, ticket_code) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id and a.ticket_code == ^ticket_code,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil ->
        Logger.warning("Attendee not found for event #{event_id} ticket #{ticket_code}")
        {:error, "NOT_FOUND", "Ticket not found"}

      %Attendee{} = attendee ->
        {:ok, attendee}
    end
  end

  defp attach_ticket_config(event_id, %Attendee{} = attendee) do
    case CacheManager.cache_get_ticket_config(event_id, attendee.ticket_type) do
      {:ok, config} ->
        updated = maybe_apply_ticket_limits(attendee, config)
        {updated, config}

      {:error, _} ->
        {attendee, nil}
    end
  end

  defp maybe_apply_ticket_limits(%Attendee{} = attendee, %{allowed_checkins: allowed})
       when is_integer(allowed) and allowed > 0 do
    remaining = attendee.checkins_remaining || allowed

    %{attendee | allowed_checkins: allowed, checkins_remaining: min(remaining, allowed)}
  end

  defp maybe_apply_ticket_limits(attendee, _config), do: attendee

  defp ensure_can_check_in(%Attendee{} = attendee) do
    cond do
      attendee.is_currently_inside ->
        Logger.warning("Attendee #{attendee.id} already inside")
        {:error, "ALREADY_INSIDE", "Attendee already inside"}

      remaining_checkins(attendee) <= 0 ->
        Logger.warning("Attendee #{attendee.id} exhausted check-ins")
        {:error, "LIMIT_EXCEEDED", "No check-ins remaining"}

      true ->
        :ok
    end
  end

  defp ensure_can_check_out(%Attendee{} = attendee) do
    cond do
      attendee.is_currently_inside ->
        :ok

      attendee.checked_in_at ->
        :ok

      true ->
        Logger.warning("Attendee #{attendee.id} cannot be checked out because no check-in exists")
        {:error, "NOT_CHECKED_IN", "Attendee has not checked in"}
    end
  end

  defp build_check_in_attributes(%Attendee{} = attendee, entrance_name) do
    now = current_timestamp()
    today = Date.utc_today()

    %{
      checked_in_at: attendee.checked_in_at || now,
      last_checked_in_at: now,
      last_checked_in_date: today,
      daily_scan_count: increment_daily_counter(attendee, today),
      weekly_scan_count: increment_counter(attendee.weekly_scan_count),
      monthly_scan_count: increment_counter(attendee.monthly_scan_count),
      checkins_remaining: max(remaining_checkins(attendee) - 1, 0),
      is_currently_inside: true,
      checked_out_at: nil,
      last_entrance: entrance_name
    }
  end

  defp increment_daily_counter(%Attendee{} = attendee, today) do
    case attendee.last_checked_in_date do
      ^today -> increment_counter(attendee.daily_scan_count)
      _ -> 1
    end
  end

  defp increment_counter(nil), do: 1
  defp increment_counter(value) when is_integer(value), do: value + 1
  defp increment_counter(_value), do: 1

  defp remaining_checkins(%Attendee{} = attendee) do
    attendee.checkins_remaining || attendee.allowed_checkins || 0
  end

  defp upsert_active_session(%Attendee{} = attendee, entrance_name) do
    now = current_timestamp()
    query = active_session_query(attendee)

    result =
      case Repo.one(query) do
        nil ->
          %CheckInSession{}
          |> CheckInSession.changeset(%{
            attendee_id: attendee.id,
            event_id: attendee.event_id,
            entry_time: now,
            entrance_name: entrance_name
          })
          |> Repo.insert()

        %CheckInSession{} = session ->
          session
          |> CheckInSession.changeset(%{entry_time: now, entrance_name: entrance_name})
          |> Repo.update()
      end

    case result do
      {:ok, session} ->
        {:ok, session}

      {:error, changeset} ->
        Logger.error(
          "Failed to store active session for attendee #{attendee.id}: #{inspect(changeset.errors)}"
        )

        {:error, {"SESSION_FAILED", "Unable to record check-in session"}}
    end
  rescue
    exception ->
      Logger.error(
        "Unexpected session error for attendee #{attendee.id}: #{Exception.message(exception)}"
      )

      {:error, {"SESSION_FAILED", "Unable to record check-in session"}}
  end

  defp close_active_session(%Attendee{} = attendee, entrance_name, exit_time) do
    query = active_session_query(attendee)

    case Repo.one(query) do
      nil ->
        Logger.error("No active session found for attendee #{attendee.id} to close")
        {:error, {"SESSION_NOT_FOUND", "No active session to complete"}}

      %CheckInSession{} = session ->
        session
        |> CheckInSession.changeset(%{exit_time: exit_time, entrance_name: entrance_name})
        |> Repo.update()
        |> case do
          {:ok, updated_session} ->
            {:ok, updated_session}

          {:error, changeset} ->
            Logger.error(
              "Failed to close session for attendee #{attendee.id}: #{inspect(changeset.errors)}"
            )

            {:error, {"SESSION_FAILED", "Unable to complete check-out session"}}
        end
    end
  rescue
    exception ->
      Logger.error(
        "Unexpected close session error for attendee #{attendee.id}: #{Exception.message(exception)}"
      )

      {:error, {"SESSION_FAILED", "Unable to complete check-out session"}}
  end

  defp active_session_query(%Attendee{} = attendee) do
    from(s in CheckInSession,
      where: s.attendee_id == ^attendee.id and s.event_id == ^attendee.event_id and is_nil(s.exit_time),
      lock: "FOR UPDATE"
    )
  end

  defp handle_session_transaction({:ok, %{attendee: attendee, message: message}}, event_id, broadcast?) do
    if broadcast?, do: broadcast_occupancy_breakdown(event_id)
    {:ok, attendee, message}
  end

  defp handle_session_transaction({:error, {code, message}}, _event_id, _broadcast?) do
    {:error, code, message}
  end

  defp handle_session_transaction({:error, reason}, _event_id, _broadcast?) do
    Logger.error("Attendee session transaction failed: #{inspect(reason)}")
    {:error, "DB_ERROR", "Unable to complete request"}
  end

  defp broadcast_occupancy_breakdown(event_id) do
    Task.start(fn ->
      breakdown = get_occupancy_breakdown(event_id)
      PubSub.broadcast(
        FastCheck.PubSub,
        "event:#{event_id}:occupancy",
        {:occupancy_breakdown_updated, event_id, breakdown}
      )
    end)

    :ok
  end

  defp elapsed_time_ms(started_at) when is_integer(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp log_check_in(result, metadata) when is_map(metadata) do
    event_name = "check_in_#{result}"
    level = log_level_for_check_in(result)

    payload =
      metadata
      |> Map.put_new(:event_id, nil)
      |> Map.put_new(:attendee_id, nil)
      |> Map.put_new(:entrance_name, nil)
      |> Map.put_new(:response_time_ms, nil)
      |> Map.put(:result, result)

    json_payload = Jason.encode!(payload)

    Logger.log(level, event_name, [
      event_id: payload[:event_id],
      attendee_id: payload[:attendee_id],
      entrance_name: payload[:entrance_name],
      response_time_ms: payload[:response_time_ms],
      payload: json_payload
    ])
  end

  defp log_level_for_check_in(result) do
    case result do
      :success -> :info
      :duplicate -> :info
      :invalid -> :info
      :update_failed -> :error
      :transaction_failed -> :error
      :exception -> :error
      _ -> :info
    end
  end

  defp current_timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp normalize_count(nil), do: 0
  defp normalize_count(value) when is_integer(value), do: value
  defp normalize_count(value) when is_float(value), do: trunc(value)
  defp normalize_count(_value), do: 0

  defp maybe_trim(nil), do: nil
  defp maybe_trim(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_trim(value), do: value

  defp record_check_in(attendee, event_id, status, entrance_name, operator_name) do
    ticket_code = attendee && Map.get(attendee, :ticket_code)

    attrs = %{
      attendee_id: attendee && Map.get(attendee, :id),
      event_id: event_id,
      ticket_code: ticket_code,
      entrance_name: entrance_name,
      operator_name: operator_name,
      status: status,
      checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %CheckIn{}
    |> CheckIn.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, check_in} -> {:ok, check_in}
      {:error, changeset} ->
        Logger.error("Failed to record check-in for #{ticket_code || "unknown"}: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp maybe_increment_occupancy(event_id, change_type)
       when is_integer(event_id) and change_type in ["entry", "exit"] do
    if occupancy_tasks_disabled?() do
      :ok
    else
      case Task.start(fn ->
             try do
               CacheManager.increment_occupancy(event_id, change_type)
             rescue
               exception ->
                 Logger.error(
                   "Failed to increment occupancy for event #{event_id} (#{change_type}): #{Exception.message(exception)}"
                 )

                 reraise(exception, __STACKTRACE__)
             catch
               kind, reason ->
                 Logger.error(
                   "Occupancy increment task crashed for event #{event_id} (#{change_type}): #{inspect({kind, reason})}"
                 )

                 :erlang.raise(kind, reason, __STACKTRACE__)
             end
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to start occupancy increment task for event #{event_id} (#{change_type}): #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp maybe_increment_occupancy(_, _), do: :ok

  defp broadcast_event_stats_async(event_id) when is_integer(event_id) do
    Task.start(fn ->
      stats = get_event_stats(event_id)
      PubSub.broadcast(FastCheck.PubSub, "event:#{event_id}:stats", {:event_stats_updated, event_id, stats})
    end)
    :ok
  end

  defp broadcast_event_stats_async(_event_id), do: :ok

  defp normalize_allowed_checkins(value) when is_integer(value) and value >= 0, do: value
  defp normalize_allowed_checkins(_), do: 1

  defp format_datetime(nil), do: "unknown time"

  defp format_datetime(datetime) do
    datetime
    |> DateTime.to_string()
  rescue
    _ -> "unknown time"
  end

  defp validate_ticket_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> validate_trimmed_value(@ticket_code_min, @ticket_code_max, @ticket_code_pattern, :ticket_code)
  end

  defp validate_ticket_code(_), do: invalid_error(:ticket_code, "is invalid")

  defp validate_entrance_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> validate_trimmed_value(@ticket_code_min, @ticket_code_max, @entrance_name_pattern, :entrance_name)
  end

  defp validate_entrance_name(_), do: invalid_error(:entrance_name, "is invalid")

  defp validate_trimmed_value(value, min, max, pattern, field) do
    if value == "" do
      invalid_error(field, "is required")
    else
      length = String.length(value)

      cond do
        length < min ->
          invalid_error(field, "must be at least #{min} characters")

        length > max ->
          invalid_error(field, "must be #{max} characters or fewer")

        not String.match?(value, pattern) ->
          invalid_error(field, "contains invalid characters")

        true ->
          {:ok, value}
      end
    end
  end

  defp invalid_error(:ticket_code, message),
    do: {:error, {:invalid_ticket_code, "Ticket code #{message}"}}

  defp invalid_error(:entrance_name, message),
    do: {:error, {:invalid_entrance_name, "Entrance name #{message}"}}

  defp occupancy_tasks_disabled? do
    Application.get_env(:fastcheck, :disable_occupancy_tasks, false)
  end
end
