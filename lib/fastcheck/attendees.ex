defmodule FastCheck.Attendees do
  @moduledoc """
  Public API facade for attendee management.

  This module orchestrates attendee operations across specialized modules:
  - `FastCheck.Attendees.Scan` - Mutations (check-in, check-out, etc.)
  - `FastCheck.Attendees.Cache` - Cached lookups and retrievals
  - `FastCheck.Attendees.Query` - Pure read-only database queries

  Functions here provide backwards compatibility and a clean public API.
  """

  require Logger

  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee
  alias FastCheck.TickeraClient

  # Orchestration Functions (true implementation)

  @doc """
  Bulk inserts attendees for the provided event.

  This is the only direct database operation in this module - it orchestrates
  parsing, validation, and batch insertion of attendees from Tickera data.

  Options:
  - `:incremental` - If true, uses upsert to update existing records (default: false)

  Returns `{:ok, count}` where `count` is the number of new/updated attendees stored.
  """
  @spec create_bulk(integer(), list(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def create_bulk(event_id, attendees_data, opts \\ [])

  def create_bulk(event_id, attendees_data, opts)
      when is_integer(event_id) and is_list(attendees_data) do
    incremental = Keyword.get(opts, :incremental, false)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

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
          conflict_target = [:event_id, :ticket_code]

          # Always upsert so syncs can correct stale fields (for example payment_status)
          # while preserving scan-state fields managed locally during check-in flow.
          {count, _} =
            Repo.insert_all(
              Attendee,
              entries,
              on_conflict:
                {:replace_all_except,
                 [
                   :id,
                   :checked_in_at,
                   :last_checked_in_at,
                   :checkins_remaining,
                   :is_currently_inside,
                   :inserted_at
                 ]},
              conflict_target: conflict_target
            )

          action = if incremental, do: "Upserted", else: "Synced"
          Logger.info("#{action} #{count} attendees for event #{event_id}")
          {:ok, count}
      end
    rescue
      exception ->
        Logger.error(
          "Bulk attendee insert failed for event #{event_id}: #{Exception.message(exception)}"
        )

        {:error, "Failed to store attendees"}
    end
  end

  def create_bulk(_event_id, _data, _opts), do: {:error, "Invalid attendee data"}

  # Delegation Functions (for backwards compatibility)

  @doc """
  Processes a check-in attempt for a ticket code.

  Delegates to `FastCheck.Attendees.Scan.check_in/4`.
  """
  @spec check_in(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in(event_id, ticket_code, entrance_name \\ "Main", operator_name \\ nil) do
    FastCheck.Attendees.Scan.check_in(event_id, ticket_code, entrance_name, operator_name)
  end

  @doc """
  Processes a list of check-in scans in a single transaction.

  Delegates to `FastCheck.Attendees.Scan.bulk_check_in/2`.
  """
  @spec bulk_check_in(integer(), list(map())) :: {:ok, list(map())} | {:error, any()}
  def bulk_check_in(event_id, scans) do
    FastCheck.Attendees.Scan.bulk_check_in(event_id, scans)
  end

  @doc """
  Performs an advanced check-in that tracks richer scan metadata.

  Delegates to `FastCheck.Attendees.Scan.check_in_advanced/5`.
  """
  @spec check_in_advanced(integer(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in_advanced(event_id, ticket_code, check_in_type, entrance_name, operator_name \\ nil) do
    FastCheck.Attendees.Scan.check_in_advanced(
      event_id,
      ticket_code,
      check_in_type,
      entrance_name,
      operator_name
    )
  end

  @doc """
  Checks an attendee out of the venue and records the session history.

  Delegates to `FastCheck.Attendees.Scan.check_out/4`.
  """
  @spec check_out(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_out(event_id, ticket_code, entrance_name, operator_name \\ nil) do
    FastCheck.Attendees.Scan.check_out(event_id, ticket_code, entrance_name, operator_name)
  end

  @doc """
  Resets the scan counters for a specific attendee.

  Delegates to `FastCheck.Attendees.Scan.reset_scan_counters/2`.
  """
  @spec reset_scan_counters(integer(), String.t()) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def reset_scan_counters(event_id, ticket_code) do
    FastCheck.Attendees.Scan.reset_scan_counters(event_id, ticket_code)
  end

  @doc """
  Marks a manual entry after validating the ticket and increments counters.

  Delegates to `FastCheck.Attendees.Scan.mark_manual_entry/5`.
  """
  @spec mark_manual_entry(integer(), String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def mark_manual_entry(event_id, ticket_code, entrance_name, operator_name \\ nil, notes \\ nil) do
    FastCheck.Attendees.Scan.mark_manual_entry(
      event_id,
      ticket_code,
      entrance_name,
      operator_name,
      notes
    )
  end

  @doc """
  Fetches a single attendee by ticket code within an event.

  Delegates to `FastCheck.Attendees.Cache.get_attendee_by_ticket_code/2`.
  """
  @spec get_attendee(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee(event_id, ticket_code) do
    FastCheck.Attendees.Cache.get_attendee_by_ticket_code(event_id, ticket_code)
  end

  @doc """
  Fetches a single attendee by id using a dedicated cache entry.

  Delegates to `FastCheck.Attendees.Cache.get_attendee!/1`.
  """
  @spec get_attendee!(integer()) :: Attendee.t()
  def get_attendee!(attendee_id) do
    FastCheck.Attendees.Cache.get_attendee!(attendee_id)
  end

  @doc """
  Removes the cached attendee lookup by id so future reads hit the database.

  Delegates to `FastCheck.Attendees.Cache.delete_attendee_id_cache/1`.
  """
  @spec delete_attendee_id_cache(integer()) :: :ok | :error
  def delete_attendee_id_cache(attendee_id) do
    FastCheck.Attendees.Cache.delete_attendee_id_cache(attendee_id)
  end

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.

  Delegates to `FastCheck.Attendees.Cache.list_event_attendees/1`.
  """
  @spec list_event_attendees(integer()) :: [Attendee.t()]
  def list_event_attendees(event_id) do
    FastCheck.Attendees.Cache.list_event_attendees(event_id)
  end

  @doc """
  Lists all check-ins for the given event ordered by most recent.

  Delegates to `FastCheck.Attendees.Query.list_event_check_ins/1`.
  """
  @spec list_event_check_ins(integer()) :: [map()]
  def list_event_check_ins(event_id) do
    FastCheck.Attendees.Query.list_event_check_ins(event_id)
  end

  @doc """
  Retrieves and caches the attendee list for an event.

  Delegates to `FastCheck.Attendees.Cache.get_attendees_by_event/2`.
  """
  @spec get_attendees_by_event(integer(), keyword()) :: [Attendee.t()]
  def get_attendees_by_event(event_id, opts \\ []) do
    FastCheck.Attendees.Cache.get_attendees_by_event(event_id, opts)
  end

  @doc """
  Removes the cached attendee list for the provided event.

  Delegates to `FastCheck.Attendees.Cache.invalidate_attendees_by_event_cache/1`.
  """
  @spec invalidate_attendees_by_event_cache(integer()) :: :ok | :error
  def invalidate_attendees_by_event_cache(event_id) do
    FastCheck.Attendees.Cache.invalidate_attendees_by_event_cache(event_id)
  end

  @doc """
  Performs a debounced attendee search scoped to a single event.

  Supports case-insensitive matches across first/last name, email, and
  ticket code fields.

  Delegates to `FastCheck.Attendees.Query.search_event_attendees/3`.
  """
  @spec search_event_attendees(integer(), String.t() | nil, pos_integer()) :: [Attendee.t()]
  def search_event_attendees(event_id, query, limit \\ 20) do
    FastCheck.Attendees.Query.search_event_attendees(event_id, query, limit)
  end

  @doc """
  Computes the real-time occupancy breakdown for a given event.

  This function orchestrates caching and computation of occupancy metrics.
  Note: This remains here as it involves orchestration of cache + computation.
  """
  @spec get_occupancy_breakdown(integer()) :: %{optional(atom()) => integer() | float()}
  def get_occupancy_breakdown(event_id) when is_integer(event_id) do
    # This orchestration logic stays in the root module as it coordinates
    # between cache and query operations
    cache_key = "occupancy:event:#{event_id}:breakdown"

    with {:ok, cached} <- fetch_from_cachex(cache_key) do
      cached
    else
      _ ->
        breakdown = FastCheck.Attendees.Query.compute_occupancy_breakdown(event_id)
        persist_to_cachex(cache_key, breakdown)
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

  @doc """
  Computes aggregate statistics for an event's attendees.

  Delegates to `FastCheck.Attendees.Query.get_event_stats/1`.
  """
  @spec get_event_stats(integer()) :: %{
          total: integer(),
          checked_in: integer(),
          pending: integer(),
          percentage: float()
        }
  def get_event_stats(event_id) do
    FastCheck.Attendees.Query.get_event_stats(event_id)
  end

  # Private Helpers

  defp normalize_allowed_checkins(value) when is_integer(value) and value >= 0, do: value
  defp normalize_allowed_checkins(_), do: 1

  defp fetch_from_cachex(cache_key) do
    if cachex_available?() do
      case Cachex.get(:fastcheck_cache, cache_key) do
        {:ok, %{} = cached} -> {:ok, cached}
        {:ok, nil} -> :miss
        {:error, _reason} -> :miss
      end
    else
      :miss
    end
  rescue
    _ -> :miss
  end

  defp persist_to_cachex(cache_key, value) do
    if cachex_available?() do
      ttl = Application.get_env(:fastcheck, :occupancy_breakdown_cache_ttl, :timer.seconds(2))
      Cachex.put(:fastcheck_cache, cache_key, value, ttl: ttl)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cachex_available? do
    Application.get_env(:fastcheck, :cache_enabled, true) and
      match?(pid when is_pid(pid), Process.whereis(:fastcheck_cache))
  end

  defp default_occupancy_breakdown do
    %{
      total: 0,
      checked_in: 0,
      checked_out: 0,
      currently_inside: 0,
      occupancy_percentage: 0.0,
      pending: 0
    }
  end
end
