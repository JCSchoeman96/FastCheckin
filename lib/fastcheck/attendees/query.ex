defmodule FastCheck.Attendees.Query do
  @moduledoc """
  Pure database query functions for attendees.

  This module contains read-only, non-mutable DB lookups with no side effects.
  Functions here perform only data retrieval and transformation without any:
  - Write operations
  - Cache updates
  - Broadcasting
  - Side effects
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.

  This is a pure database query with no caching or side effects.
  Includes a timeout to prevent long-running queries.
  """
  @spec list_event_attendees(integer()) :: [Attendee.t()]
  def list_event_attendees(event_id) when is_integer(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id,
      order_by: [desc: a.checked_in_at],
      limit: 10_000
    )
    |> Repo.all(timeout: 15_000)
  rescue
    exception ->
      if query_timeout_exception?(exception) do
        Logger.error("Query timeout listing attendees for event #{event_id}")
      else
        Logger.error("Database error listing attendees: #{Exception.message(exception)}")
      end

      []
  end

  def list_event_attendees(_), do: []

  @doc """
  Fetches a single attendee by ticket code within an event.

  This is a pure database query without caching.
  Includes a timeout for fast failure on slow queries.
  """
  @spec get_attendee_by_ticket_code(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee_by_ticket_code(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    Repo.get_by(Attendee, [event_id: event_id, ticket_code: ticket_code], timeout: 5_000)
  rescue
    exception ->
      if query_timeout_exception?(exception) do
        Logger.error(
          "Query timeout fetching attendee for event #{event_id} ticket #{ticket_code}"
        )
      else
        Logger.error("Database error fetching attendee: #{Exception.message(exception)}")
      end

      nil
  end

  def get_attendee_by_ticket_code(_, _), do: nil

  @doc """
  Fetches an attendee with a database lock for update operations.

  Uses `FOR UPDATE NOWAIT` to lock the row for safe concurrent updates while
  fast-failing under lock contention.
  Returns `{:ok, attendee}` or `{:error, code, message}`.

  Includes a 5-second timeout to prevent long-running queries.
  """
  @spec fetch_attendee_for_update(integer(), String.t()) ::
          {:ok, Attendee.t()} | {:error, String.t(), String.t()}
  def fetch_attendee_for_update(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id and a.ticket_code == ^ticket_code,
        lock: "FOR UPDATE NOWAIT"
      )

    case Repo.one(query, timeout: 5_000) do
      nil ->
        Logger.warning("Attendee not found for event #{event_id} ticket #{ticket_code}")
        {:error, "NOT_FOUND", "Ticket not found"}

      %Attendee{scan_eligibility: "not_scannable"} ->
        {:error, "TICKET_NOT_SCANNABLE", "This ticket is no longer valid for scanning"}

      %Attendee{} = attendee ->
        {:ok, attendee}
    end
  rescue
    exception ->
      cond do
        lock_not_available?(exception) ->
          {:error, "TICKET_IN_USE_ELSEWHERE", "Ticket is currently being processed"}

        query_timeout_exception?(exception) ->
          Logger.error(
            "Query timeout fetching attendee for event #{event_id} ticket #{ticket_code}"
          )

          {:error, "TIMEOUT", "Database query timed out"}

        true ->
          Logger.error("Database error fetching attendee: #{Exception.message(exception)}")
          {:error, "ERROR", "Database error"}
      end
  end

  def fetch_attendee_for_update(_, _), do: {:error, "INVALID_PARAMS", "Invalid parameters"}

  @doc """
  Performs a debounced attendee search scoped to a single event.

  Supports case-insensitive matches across first/last name, email, and
  ticket code fields, plus purchaser metadata stored in `custom_fields`.

  ## Parameters
  - `event_id` - The event to search within
  - `query` - Search term (string)
  - `limit` - Maximum results (default: 20, max: 50)

  ## Returns
  List of matching attendees, ordered by last name, first name, and ID.
  """
  @spec search_event_attendees(integer(), String.t() | nil, pos_integer()) :: [Attendee.t()]
  def search_event_attendees(event_id, query, limit \\ 20)

  def search_event_attendees(event_id, query, limit) when is_integer(event_id) do
    trimmed = sanitize_query(query)

    if trimmed == "" do
      []
    else
      do_search_event_attendees(event_id, trimmed, normalize_limit(limit))
    end
  rescue
    exception ->
      Logger.error(
        "Attendee search failed for event #{event_id}: #{Exception.message(exception)}"
      )

      []
  end

  def search_event_attendees(_, _, _), do: []

  @doc """
  Performs scanner-focused attendee search with truncation metadata.

  Returns the first `limit` attendees plus a boolean indicating whether more
  matches existed beyond the visible result cap.
  """
  @spec search_event_attendees_with_meta(integer(), String.t() | nil, pos_integer()) :: %{
          rows: [Attendee.t()],
          truncated?: boolean()
        }
  def search_event_attendees_with_meta(event_id, query, limit \\ 50)

  def search_event_attendees_with_meta(event_id, query, limit) when is_integer(event_id) do
    trimmed = sanitize_query(query)

    if trimmed == "" do
      %{rows: [], truncated?: false}
    else
      safe_limit = normalize_limit(limit)
      fetched_rows = do_search_event_attendees(event_id, trimmed, safe_limit + 1)

      %{
        rows: Enum.take(fetched_rows, safe_limit),
        truncated?: length(fetched_rows) > safe_limit
      }
    end
  rescue
    exception ->
      Logger.error(
        "Scanner attendee search failed for event #{event_id}: #{Exception.message(exception)}"
      )

      %{rows: [], truncated?: false}
  end

  def search_event_attendees_with_meta(_, _, _), do: %{rows: [], truncated?: false}

  @doc """
  Computes the real-time occupancy breakdown for a given event.

  This is a pure database query that computes aggregate statistics across
  all attendees for an event without any caching or side effects.
  """
  @spec compute_occupancy_breakdown(integer()) :: %{optional(atom()) => integer() | float()}
  def compute_occupancy_breakdown(event_id) when is_integer(event_id) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id,
        select: %{
          total: count(a.id),
          checked_in: fragment("sum(case when ? IS NOT NULL then 1 else 0 end)", a.checked_in_at),
          checked_out:
            fragment("sum(case when ? IS NOT NULL then 1 else 0 end)", a.checked_out_at),
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

  def compute_occupancy_breakdown(_), do: default_occupancy_breakdown()

  @doc """
  Lists all check-ins for the given event ordered by most recent.

  Includes attendee information via preload.
  """
  @spec list_event_check_ins(integer()) :: [map()]
  def list_event_check_ins(event_id) when is_integer(event_id) do
    alias FastCheck.Attendees.CheckIn

    from(ci in CheckIn,
      where: ci.event_id == ^event_id,
      order_by: [desc: ci.checked_in_at],
      preload: [:attendee],
      limit: 50_000
    )
    |> Repo.all(timeout: 30_000)
  rescue
    exception ->
      if query_timeout_exception?(exception) do
        Logger.error("Query timeout listing check-ins for event #{event_id}")
      else
        Logger.error("Database error listing check-ins: #{Exception.message(exception)}")
      end

      []
  end

  def list_event_check_ins(_), do: []

  @doc """
  Computes aggregate statistics for an event's attendees.

  This is a pure database query without caching.
  """
  @spec get_event_stats(integer()) :: %{
          total: integer(),
          checked_in: integer(),
          pending: integer(),
          percentage: float()
        }
  def get_event_stats(event_id) when is_integer(event_id) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id,
        select: %{
          total: count(a.id),
          checked_in: fragment("sum(case when ? IS NOT NULL then 1 else 0 end)", a.checked_in_at)
        }
      )

    case Repo.one(query) do
      nil ->
        %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}

      %{total: total, checked_in: checked_in} ->
        total_int = normalize_count(total)
        checked_in_int = normalize_count(checked_in)
        pending = max(total_int - checked_in_int, 0)

        percentage =
          if total_int == 0, do: 0.0, else: Float.round(checked_in_int / total_int * 100, 2)

        %{
          total: total_int,
          checked_in: checked_in_int,
          pending: pending,
          percentage: percentage
        }
    end
  rescue
    exception ->
      Logger.error(
        "Failed to compute stats for event #{event_id}: #{Exception.message(exception)}"
      )

      %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}
  end

  def get_event_stats(_), do: %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}

  # Private Helpers

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

  defp normalize_count(nil), do: 0
  defp normalize_count(value) when is_integer(value), do: value
  defp normalize_count(value) when is_float(value), do: trunc(value)
  defp normalize_count(_value), do: 0

  defp sanitize_query(nil), do: ""
  defp sanitize_query(query) when is_binary(query), do: String.trim(query)
  defp sanitize_query(query), do: query |> to_string() |> String.trim()

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 50)
  defp normalize_limit(_limit), do: 20

  defp do_search_event_attendees(event_id, trimmed_query, limit) do
    pattern = "%#{escape_like(trimmed_query)}%"

    from(a in Attendee,
      where: a.event_id == ^event_id,
      where: ^search_pattern_match(pattern),
      order_by: [asc: a.last_name, asc: a.first_name, asc: a.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp search_pattern_match(pattern) do
    dynamic(
      [a],
      ilike(a.first_name, ^pattern) or
        ilike(a.last_name, ^pattern) or
        ilike(a.email, ^pattern) or
        ilike(a.ticket_code, ^pattern) or
        fragment("coalesce(?->>?, '') ILIKE ?", a.custom_fields, "buyer_first", ^pattern) or
        fragment("coalesce(?->>?, '') ILIKE ?", a.custom_fields, "buyer_last", ^pattern) or
        fragment("coalesce(?->>?, '') ILIKE ?", a.custom_fields, "buyer_email", ^pattern) or
        fragment(
          "trim(concat_ws(' ', coalesce(?->>?, ''), coalesce(?->>?, ''))) ILIKE ?",
          a.custom_fields,
          "buyer_first",
          a.custom_fields,
          "buyer_last",
          ^pattern
        )
    )
  end

  defp escape_like(term) when is_binary(term) do
    term
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp lock_not_available?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_not_available?(_), do: false

  defp query_timeout_exception?(%{__struct__: struct}) when is_atom(struct),
    do: Atom.to_string(struct) == "Elixir.DBConnection.QueryError"
end
