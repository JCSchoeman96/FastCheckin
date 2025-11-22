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

  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee

  @doc """
  Lists all attendees for the given event ordered by most recent check-in.

  This is a pure database query with no caching or side effects.
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
  Fetches a single attendee by ticket code within an event.

  This is a pure database query without caching.
  """
  @spec get_attendee_by_ticket_code(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee_by_ticket_code(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
    Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code)
  end

  def get_attendee_by_ticket_code(_, _), do: nil

  @doc """
  Fetches an attendee with a database lock for update operations.

  Uses `FOR UPDATE` to lock the row for safe concurrent updates.
  Returns `{:ok, attendee}` or `{:error, code, message}`.
  """
  @spec fetch_attendee_for_update(integer(), String.t()) ::
          {:ok, Attendee.t()} | {:error, String.t(), String.t()}
  def fetch_attendee_for_update(event_id, ticket_code)
      when is_integer(event_id) and is_binary(ticket_code) do
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

  def fetch_attendee_for_update(_, _), do: {:error, "INVALID_PARAMS", "Invalid parameters"}

  @doc """
  Performs a debounced attendee search scoped to a single event.

  Supports case-insensitive matches across first/last name, email, and
  ticket code fields.

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
      Logger.error(
        "Attendee search failed for event #{event_id}: #{Exception.message(exception)}"
      )

      []
  end

  def search_event_attendees(_, _, _), do: []

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
        Logger.error(
          "Failed to compute stats for event #{event_id}: #{Exception.message(exception)}"
        )

        %{total: 0, checked_in: 0, pending: 0, percentage: 0.0}
    end
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

  defp escape_like(term) when is_binary(term) do
    term
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp escape_like(term), do: term
end
