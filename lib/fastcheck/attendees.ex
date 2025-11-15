defmodule FastCheck.Attendees do
  @moduledoc """
  Context responsible for attendee persistence, ticket scanning, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias PetalBlueprint.Repo
  alias Phoenix.PubSub
  alias FastCheck.{
    Attendees.Attendee,
    Attendees.CheckIn,
    Attendees.CheckInSession,
    Cache.CacheManager,
    TickeraClient
  }

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

  Returns `{:ok, attendee, "SUCCESS"}` when the scan is valid, otherwise
  `{:error, code, message}` describing the failure.
  """
  @spec check_in(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in(event_id, ticket_code, entrance_name \\ "Main", operator_name \\ nil)
      when is_integer(event_id) and is_binary(ticket_code) do
    query =
      from(a in Attendee,
        where: a.event_id == ^event_id and a.ticket_code == ^ticket_code,
        lock: "FOR UPDATE"
      )

    try do
      Repo.transaction(fn ->
        case Repo.one(query) do
          nil ->
            Logger.warn("Invalid ticket #{ticket_code} for event #{event_id}")
            record_check_in(%{ticket_code: ticket_code}, event_id, "invalid", entrance_name, operator_name)
            broadcast_event_stats_async(event_id)
            {:error, "INVALID", "Ticket not found"}

          %Attendee{} = attendee ->
            remaining = attendee.checkins_remaining || attendee.allowed_checkins || 0

            cond do
              attendee.checked_in_at && remaining <= 0 ->
                Logger.warn("Duplicate ticket #{ticket_code} for event #{event_id}")
                record_check_in(attendee, event_id, "duplicate", entrance_name, operator_name)
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
                    record_check_in(updated, event_id, "success", entrance_name, operator_name)
                    broadcast_event_stats_async(event_id)
                    Logger.info("Ticket #{ticket_code} checked in for event #{event_id}")
                    {:ok, updated, "SUCCESS"}

                  {:error, changeset} ->
                    Logger.error("Failed to update attendee #{attendee.id}: #{inspect(changeset.errors)}")
                    Repo.rollback({:changeset, "Failed to update attendee"})
                end
            end
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, {:changeset, message}} -> {:error, "ERROR", message}
        {:error, reason} ->
          Logger.error("Check-in transaction failed for #{ticket_code}: #{inspect(reason)}")
          {:error, "ERROR", "Unable to process check-in"}
      end
    rescue
      exception ->
        Logger.error("Check-in crashed for #{ticket_code}: #{Exception.message(exception)}")
        {:error, "ERROR", "Unexpected error"}
    end
  end

  def check_in(_, _, _, _), do: {:error, "INVALID", "Ticket not found"}

  @doc """
  Performs an advanced check-in that tracks the richer scan metadata and
  updates the attendee counters atomically.

  Returns `{:ok, attendee, "SUCCESS"}` on success or
  `{:error, code, message}` on validation/database failures.
  """
  @spec check_in_advanced(integer(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in_advanced(event_id, ticket_code, check_in_type, entrance_name, operator_name \\
        nil)
      when is_integer(event_id) and is_binary(ticket_code) and is_binary(check_in_type) and
             is_binary(entrance_name) do
    sanitized_code = ticket_code |> String.trim()
    sanitized_type = check_in_type |> String.trim()
    sanitized_entrance = entrance_name |> String.trim()

    cond do
      sanitized_code == "" ->
        Logger.warn("Advanced check-in rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_type == "" ->
        Logger.warn("Advanced check-in rejected: blank check-in type")
        {:error, "INVALID_TYPE", "Check-in type is required"}

      sanitized_entrance == "" ->
        Logger.warn("Advanced check-in rejected: blank entrance name")
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
      when is_integer(event_id) and is_binary(ticket_code) and is_binary(entrance_name) do
    sanitized_code = String.trim(ticket_code)
    sanitized_entrance = String.trim(entrance_name)

    cond do
      sanitized_code == "" ->
        Logger.warn("Check-out rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_entrance == "" ->
        Logger.warn("Check-out rejected: blank entrance name")
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
      Logger.warn("Reset scan counters rejected: blank ticket code")
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
      when is_integer(event_id) and is_binary(ticket_code) and is_binary(entrance_name) do
    sanitized_code = String.trim(ticket_code)
    sanitized_entrance = String.trim(entrance_name)

    cond do
      sanitized_code == "" ->
        Logger.warn("Manual entry rejected: blank ticket code")
        {:error, "INVALID_TICKET", "Ticket code is required"}

      sanitized_entrance == "" ->
        Logger.warn("Manual entry rejected: blank entrance name")
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
        %{total: 0, checked_in: 0, checked_out: 0, currently_inside: 0, occupancy_percentage: 0.0}

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
  rescue
    exception ->
      Logger.error("Failed to compute occupancy breakdown for event #{event_id}: #{Exception.message(exception)}")
      %{total: 0, checked_in: 0, checked_out: 0, currently_inside: 0, occupancy_percentage: 0.0, pending: 0}
  end

  def get_occupancy_breakdown(_),
    do: %{total: 0, checked_in: 0, checked_out: 0, currently_inside: 0, occupancy_percentage: 0.0, pending: 0}

  @doc """
  Fetches a single attendee by ticket code within an event.
  """
  @spec get_attendee(integer(), String.t()) :: Attendee.t() | nil
  def get_attendee(event_id, ticket_code) when is_integer(event_id) and is_binary(ticket_code) do
    Repo.get_by(Attendee, event_id: event_id, ticket_code: ticket_code)
  end

  def get_attendee(_, _), do: nil

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
  def search_event_attendees(event_id, query, limit \\ 20) when is_integer(event_id) do
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
          Logger.warn("Advanced check-in aborted for #{ticket_code}: #{code}")
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
          Logger.warn("Check-out aborted for #{ticket_code}: #{code}")
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
          Logger.warn("Reset scan counters aborted for #{ticket_code}: #{code}")
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
          Logger.warn("Manual entry aborted for #{ticket_code}: #{code}")
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
        Logger.warn("Attendee not found for event #{event_id} ticket #{ticket_code}")
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
        Logger.warn("Attendee #{attendee.id} already inside")
        {:error, "ALREADY_INSIDE", "Attendee already inside"}

      remaining_checkins(attendee) <= 0 ->
        Logger.warn("Attendee #{attendee.id} exhausted check-ins")
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
        Logger.warn("Attendee #{attendee.id} cannot be checked out because no check-in exists")
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
      daily_scan_count: increment_counter(attendee.daily_scan_count),
      weekly_scan_count: increment_counter(attendee.weekly_scan_count),
      monthly_scan_count: increment_counter(attendee.monthly_scan_count),
      checkins_remaining: max(remaining_checkins(attendee) - 1, 0),
      is_currently_inside: true,
      checked_out_at: nil,
      last_entrance: entrance_name
    }
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
        PetalBlueprint.PubSub,
        "event:#{event_id}:occupancy",
        {:occupancy_breakdown_updated, event_id, breakdown}
      )
    end)

    :ok
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

  defp maybe_increment_occupancy(_, _), do: :ok

  defp broadcast_event_stats_async(event_id) when is_integer(event_id) do
    Task.start(fn ->
      stats = get_event_stats(event_id)
      PubSub.broadcast(PetalBlueprint.PubSub, "event:#{event_id}:stats", {:event_stats_updated, event_id, stats})
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
end
