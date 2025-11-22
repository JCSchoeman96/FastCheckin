defmodule FastCheck.Attendees.Scan do
  @moduledoc """
  Handles all mutable scan operations: check-in, check-out, manual entries, and session tracking.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Repo
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Attendees.CheckIn
  alias FastCheck.Attendees.CheckInSession
  alias FastCheck.Attendees.Query
  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.Events
  alias FastCheck.Events.Stats
  alias Phoenix.PubSub

  @ticket_code_min 3
  @ticket_code_max 100
  @ticket_code_pattern ~r/^[A-Za-z0-9\-\._]+$/
  @entrance_name_pattern ~r/^[A-Za-z0-9\s\-\._]+$/
  @cache_name :fastcheck_cache

  @doc """
  Processes a check-in attempt for a ticket code.
  """
  @spec check_in(integer(), String.t(), String.t(), String.t() | nil) ::
          {:ok, Attendee.t(), String.t()} | {:error, String.t(), String.t()}
  def check_in(event_id, ticket_code, entrance_name \\ "Main", operator_name \\ nil)

  def check_in(event_id, ticket_code, entrance_name, operator_name)
      when is_integer(event_id) and is_binary(ticket_code) and
             is_binary(entrance_name) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- ensure_scanning_allowed(event_id),
         {:ok, sanitized_code} <- validate_ticket_code(ticket_code),
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

              record_check_in(
                %{ticket_code: sanitized_code},
                event_id,
                "invalid",
                sanitized_entrance,
                operator_name
              )

              broadcast_event_stats_async(event_id)
              {:error, "INVALID", "Ticket not found"}

            %Attendee{} = attendee ->
              remaining = attendee.checkins_remaining || attendee.allowed_checkins || 0

              cond do
                # Reject tickets with invalid payment status
                not is_payment_status_valid?(attendee.payment_status) ->
                  Logger.warning(
                    "Check-in rejected due to invalid payment status: #{attendee.payment_status}",
                    ticket_code: sanitized_code,
                    event_id: event_id,
                    payment_status: attendee.payment_status
                  )

                  record_check_in(
                    attendee,
                    event_id,
                    "payment_invalid",
                    sanitized_entrance,
                    operator_name
                  )

                  broadcast_event_stats_async(event_id)

                  {:error, "PAYMENT_INVALID",
                   "Ticket payment status is invalid: #{normalize_payment_status(attendee.payment_status)}"}

                attendee.checked_in_at && remaining <= 0 ->
                  Logger.warning("Duplicate ticket #{sanitized_code} for event #{event_id}")

                  record_check_in(
                    attendee,
                    event_id,
                    "duplicate",
                    sanitized_entrance,
                    operator_name
                  )

                  broadcast_event_stats_async(event_id)

                  {:error, "DUPLICATE",
                   "Already checked in at #{format_datetime(attendee.checked_in_at)}"}

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

                      record_check_in(
                        updated,
                        event_id,
                        "success",
                        sanitized_entrance,
                        operator_name
                      )

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
          {:ok, result} ->
            result

          {:error, {:changeset, message}} ->
            {:error, "ERROR", message}

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
      {:error, code, message} when is_binary(code) ->
        Logger.warning("Check-in rejected for event #{event_id}: #{message}")
        {:error, code, message}

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
  Processes a list of check-in scans in a single transaction.
  """
  @spec bulk_check_in(integer(), list(map())) :: {:ok, list(map())} | {:error, any()}
  def bulk_check_in(event_id, scans) when is_integer(event_id) and is_list(scans) do
    Repo.transaction(fn ->
      Enum.map(scans, fn scan ->
        ticket_code = Map.get(scan, "ticket_code")
        entrance = Map.get(scan, "entrance_name", "Main")
        operator = Map.get(scan, "operator_name")

        if is_binary(ticket_code) do
          case check_in(event_id, ticket_code, entrance, operator) do
            {:ok, attendee, status} ->
              %{
                ticket_code: ticket_code,
                status: status,
                attendee_id: attendee.id,
                checkins_remaining: attendee.checkins_remaining
              }

            {:error, code, message} ->
              %{
                ticket_code: ticket_code,
                status: "ERROR",
                error_code: code,
                message: message
              }
          end
        else
          %{
            ticket_code: nil,
            status: "ERROR",
            error_code: "MISSING_TICKET_CODE",
            message: "Ticket code is required"
          }
        end
      end)
    end)
  end

  @doc """
  Performs an advanced check-in that tracks the richer scan metadata and
  updates the attendee counters atomically.
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

  # Private Helpers

  defp do_advanced_check_in(event_id, ticket_code, check_in_type, entrance_name, operator_name) do
    with :ok <- ensure_scanning_allowed(event_id) do
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
              Logger.error(
                "Advanced check-in update failed for #{ticket_code}: #{inspect(changeset.errors)}"
              )

              Repo.rollback({"UPDATE_FAILED", "Unable to process advanced check-in"})
          end
        else
          {:error, code, message} ->
            Logger.warning("Advanced check-in aborted for #{ticket_code}: #{code}")
            Repo.rollback({code, message})
        end
      end)
      |> handle_session_transaction(event_id, true)
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp do_check_out(event_id, ticket_code, entrance_name, operator_name) do
    with :ok <- ensure_scanning_allowed(event_id) do
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
              Logger.error(
                "Check-out update failed for #{ticket_code}: #{inspect(changeset.errors)}"
              )

              Repo.rollback({"UPDATE_FAILED", "Unable to complete check-out"})
          end
        else
          {:error, code, message} ->
            Logger.warning("Check-out aborted for #{ticket_code}: #{code}")
            Repo.rollback({code, message})
        end
      end)
      |> handle_session_transaction(event_id, true)
    else
      {:error, code, message} -> {:error, code, message}
    end
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
            Logger.error(
              "Reset scan counters failed for #{ticket_code}: #{inspect(changeset.errors)}"
            )

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
    with :ok <- ensure_scanning_allowed(event_id) do
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
              Logger.error(
                "Manual entry update failed for #{ticket_code}: #{inspect(changeset.errors)}"
              )

              Repo.rollback({"UPDATE_FAILED", "Unable to mark manual entry"})
          end
        else
          {:error, code, message} ->
            Logger.warning("Manual entry aborted for #{ticket_code}: #{code}")
            Repo.rollback({code, message})
        end
      end)
      |> handle_session_transaction(event_id, true)
    else
      {:error, code, message} -> {:error, code, message}
    end
  end

  defp ensure_scanning_allowed(event_id) do
    case Repo.get(Event, event_id) do
      nil ->
        Logger.warning("Scan attempt blocked for missing event #{event_id}")
        {:error, "EVENT_NOT_FOUND", "Event not found"}

      %Event{} = event ->
        case Events.can_check_in?(event) do
          {:ok, _state} ->
            :ok

          {:error, {:event_archived, message}} ->
            Logger.warning("Scan attempt blocked for archived event #{event_id}")
            {:error, "ARCHIVED_EVENT", message}

          {:error, {_reason, message}} ->
            {:error, "SCANS_DISABLED", message || "Scanning disabled"}
        end
    end
  end

  defp validate_ticket_code(value) when is_binary(value) do
    value
    |> String.trim()
    |> validate_trimmed_value(
      @ticket_code_min,
      @ticket_code_max,
      @ticket_code_pattern,
      :ticket_code
    )
  end

  defp validate_ticket_code(_value) when true,
    do: invalid_error(:ticket_code, "is invalid")

  defp validate_entrance_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> validate_trimmed_value(
      @ticket_code_min,
      @ticket_code_max,
      @entrance_name_pattern,
      :entrance_name
    )
  end

  defp validate_entrance_name(_value) when true,
    do: invalid_error(:entrance_name, "is invalid")

  defp validate_trimmed_value(value, min, max, pattern, field) when is_binary(value) do
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

  defp is_payment_status_valid?(status) when status in [nil, "paid", "completed", "free"],
    do: true

  defp is_payment_status_valid?(_status), do: false

  defp normalize_payment_status(nil), do: "unknown"
  defp normalize_payment_status(status) when is_binary(status), do: status
  defp normalize_payment_status(_), do: "unknown"

  defp format_datetime(nil), do: "unknown time"

  defp format_datetime(datetime) do
    datetime
    |> DateTime.to_string()
  rescue
    _ -> "unknown time"
  end

  defp invalidate_check_in_caches(%Attendee{id: attendee_id}, event_id, ticket_code)
       when is_integer(event_id) and is_binary(ticket_code) do
    delete_attendee_cache_entry(event_id, ticket_code)
    FastCheck.Attendees.delete_attendee_id_cache(attendee_id)
    delete_cache_entry("attendees:event:#{event_id}", "event attendees cache")
    delete_cache_entry("stats:#{event_id}", "event stats cache")
    purge_local_occupancy_breakdown(event_id)
    :ok
  end

  defp invalidate_check_in_caches(_, _, _), do: :ok

  defp delete_attendee_cache_entry(event_id, ticket_code) do
    EtsLayer.delete_attendee(event_id, ticket_code)

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
      Logger.warning(
        "Cache delete raised for #{description} (#{key}): #{Exception.message(exception)}"
      )

      :error
  end

  defp purge_local_occupancy_breakdown(event_id) do
    cache_key = occupancy_cache_key(event_id)

    if occupancy_cache_available?() do
      case Cachex.del(@cache_name, cache_key) do
        {:ok, _} ->
          :ok

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
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to refresh occupancy for event #{event_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Occupancy refresh raised for event #{event_id}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp refresh_event_occupancy(_), do: :ok

  defp occupancy_cache_key(event_id), do: "occupancy:event:#{event_id}:breakdown"

  defp occupancy_cache_available? do
    Elixir.Application.get_env(:fastcheck, :cache_enabled, true) and
      match?(pid when is_pid(pid), Process.whereis(@cache_name))
  end

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
      {:ok, check_in} ->
        {:ok, check_in}

      {:error, changeset} ->
        Logger.error(
          "Failed to record check-in for #{ticket_code || "unknown"}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp broadcast_event_stats_async(event_id) when is_integer(event_id) do
    Task.start(fn ->
      stats = Events.get_event_stats(event_id)

      PubSub.broadcast(
        FastCheck.PubSub,
        "event:#{event_id}:stats",
        {:event_stats_updated, event_id, stats}
      )
    end)

    :ok
  end

  defp broadcast_event_stats_async(_event_id), do: :ok

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

    Logger.log(level, event_name,
      event_id: payload[:event_id],
      attendee_id: payload[:attendee_id],
      entrance_name: payload[:entrance_name],
      response_time_ms: payload[:response_time_ms],
      payload: json_payload
    )
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

  defp fetch_attendee_for_update(event_id, ticket_code) do
    Query.fetch_attendee_for_update(event_id, ticket_code)
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

  defp remaining_checkins(%Attendee{} = attendee) do
    attendee.checkins_remaining || attendee.allowed_checkins || 0
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

  defp current_timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp increment_daily_counter(%Attendee{} = attendee, today) do
    case attendee.last_checked_in_date do
      ^today -> increment_counter(attendee.daily_scan_count)
      _ -> 1
    end
  end

  defp increment_counter(nil), do: 1
  defp increment_counter(value) when is_integer(value), do: value + 1

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

  defp occupancy_tasks_disabled? do
    Elixir.Application.get_env(:fastcheck, :disable_occupancy_tasks, false)
  end

  defp handle_session_transaction(
         {:ok, %{attendee: attendee, message: message}},
         event_id,
         broadcast?
       ) do
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
    Stats.broadcast_occupancy_breakdown(event_id)
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
      where:
        s.attendee_id == ^attendee.id and s.event_id == ^attendee.event_id and is_nil(s.exit_time),
      lock: "FOR UPDATE"
    )
  end

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
end
