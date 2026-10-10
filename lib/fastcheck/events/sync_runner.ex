defmodule FastCheck.Events.SyncRunner do
  @moduledoc """
  Explicit, non-default guarded SyncRun execution path.

  Production callers remain on `FastCheck.Events.Sync` until the later cutover phase.
  """

  alias FastCheck.Attendees
  alias FastCheck.Attendees.Reconciliation
  alias FastCheck.Events
  alias FastCheck.Events.{Cache, Event, Stats, SyncRun, SyncState}
  alias FastCheck.Repo
  alias FastCheck.TickeraClient

  @per_page 50

  @spec run(
          integer(),
          function() | nil,
          (pos_integer(), pos_integer() | nil, non_neg_integer() -> any()) | nil,
          keyword()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def run(event_id, authority_guard, progress_callback \\ nil, opts \\ [])

  def run(event_id, authority_guard, progress_callback, opts)
      when is_integer(event_id) and is_list(opts) do
    with :ok <- validate_guard(authority_guard),
         {:ok, incremental, max_attempts, before_owner_write} <- validate_options(opts),
         :ok <- authority_check(authority_guard, event_id),
         {:ok, run} <- SyncRun.claim(event_id) do
      :ok = SyncState.init_sync(event_id, run.sync_run_id, run.owner_token, run.id)

      context = %{
        event_id: event_id,
        run: run,
        guard: authority_guard,
        callback: progress_callback,
        incremental: incremental,
        max_attempts: max_attempts,
        before_owner_write: before_owner_write,
        pages: 0
      }

      execute(context)
    end
  end

  def run(_event_id, _authority_guard, _progress_callback, _opts),
    do: {:error, :authority_required}

  defp execute(context) do
    case Repo.get(Event, context.event_id) do
      nil -> finish_failure(context, :worker_failed)
      event -> execute_for_event(context, event)
    end
  end

  defp execute_for_event(context, event) do
    with {:ok, api_key} <- Events.Sync.get_tickera_api_key(event),
         {:ok, essentials} <-
           request_with_retry(context, fn hook ->
             TickeraClient.get_event_essentials_guarded(event.tickera_site_url, api_key, hook)
           end),
         :ok <- persist_event_essentials(context, event, essentials),
         {:ok, attendees, page_count, final_context} <-
           fetch_pages(context, event, api_key, 1, [], 0) do
      persist_snapshot(final_context, event, attendees, page_count)
    else
      {:error, :authority_revoked} ->
        finish_cancel(context, :authority_revoked)

      {:error, :paused} ->
        {:error, :paused}

      {:error, :stale_owner} ->
        {:error, :stale_owner}

      {:error, :authority_revoked, failed_context} ->
        finish_cancel(failed_context, :authority_revoked)

      {:error, :paused, _failed_context} ->
        {:error, :paused}

      {:error, :stale_owner, _failed_context} ->
        {:error, :stale_owner}

      {:error, reason, failed_context} ->
        finish_failure(failed_context, safe_failure_reason(reason))

      {:error, reason} ->
        finish_failure(context, safe_failure_reason(reason))
    end
  end

  defp fetch_pages(context, event, api_key, page, acc, count) do
    result =
      request_with_retry(context, fn hook ->
        TickeraClient.get_tickets_info_guarded(
          event.tickera_site_url,
          api_key,
          @per_page,
          page,
          hook
        )
      end)

    case result do
      {:ok, response} ->
        with {:ok, rows} <- extract_page(response),
             next_count = count + length(rows),
             {:ok, next_context} <- record_progress(context, page, next_count) do
          next_acc = Enum.reverse(rows, acc)

          if length(rows) == @per_page do
            fetch_pages(next_context, event, api_key, page + 1, next_acc, next_count)
          else
            {:ok, Enum.reverse(next_acc), next_count, next_context}
          end
        else
          {:error, reason} -> {:error, reason, context}
        end

      {:error, reason} ->
        {:error, reason, context}
    end
  end

  defp request_with_retry(context, dispatch, attempt \\ 1) do
    hook = fn -> before_dispatch(context) end

    result = dispatch.(hook)

    case post_response_fence(context) do
      :ok ->
        case result do
          {:ok, response} ->
            {:ok, response}

          {:error, :paused} ->
            {:error, :paused}

          {:error, :stale_owner} ->
            {:error, :stale_owner}

          {:error, _reason} when attempt < context.max_attempts ->
            request_with_retry(context, dispatch, attempt + 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp before_dispatch(context) do
    with :ok <- authority_check(context.guard, context.event_id),
         {:ok, _run} <-
           SyncRun.prepare_request(
             context.event_id,
             context.run.sync_run_id,
             context.run.owner_token
           ) do
      :ok
    end
  end

  defp post_response_fence(context) do
    with :ok <- authority_check(context.guard, context.event_id),
         :ok <-
           SyncRun.check_owner(
             context.event_id,
             context.run.sync_run_id,
             context.run.owner_token
           ) do
      :ok
    else
      {:error, :authority_revoked} ->
        finish_cancel(context, :authority_revoked)
        {:error, :authority_revoked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_progress(context, page, count) do
    total_pages = nil

    with {:ok, _run} <-
           SyncRun.update_progress(
             context.event_id,
             context.run.sync_run_id,
             context.run.owner_token,
             page,
             total_pages,
             count
           ),
         :ok <-
           SyncState.update_progress(
             context.event_id,
             context.run.sync_run_id,
             context.run.owner_token,
             page,
             total_pages,
             count
           ) do
      invoke_callback(context.callback, page, total_pages, count)
      {:ok, %{context | pages: page}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_event_essentials(context, _event, essentials) do
    with :ok <- authority_check(context.guard, context.event_id),
         :ok <- invoke_owner_write_hook(context, :event_essentials),
         {:ok, write_result} <-
           SyncRun.with_owned_write(
             context.event_id,
             context.run.sync_run_id,
             context.run.owner_token,
             fn locked_event, _run ->
               total = extract_total_tickets(essentials)
               start_date = normalize_remote_datetime(Map.get(essentials, "event_start_date"))
               end_date = normalize_remote_datetime(Map.get(essentials, "event_end_date"))

               attrs =
                 [
                   total_tickets: total,
                   tickera_start_date: start_date,
                   tickera_end_date: end_date
                 ]
                 |> Enum.reject(fn
                   {:total_tickets, nil} -> true
                   {_field, nil} -> true
                   {field, value} -> Map.get(locked_event, field) == value
                 end)
                 |> Map.new()

               if map_size(attrs) > 0 do
                 case locked_event |> Event.changeset(attrs) |> Repo.update() do
                   {:ok, updated} -> {:updated, updated}
                   {:error, _changeset} -> Repo.rollback(:worker_failed)
                 end
               else
                 :unchanged
               end
             end
           ) do
      case write_result do
        {:updated, updated} ->
          _ = Cache.invalidate_event_cache(updated.id)
          _ = Cache.invalidate_events_list_cache()
          :ok

        :unchanged ->
          :ok
      end
    end
  end

  defp normalize_remote_datetime(%DateTime{} = value), do: DateTime.truncate(value, :second)

  defp normalize_remote_datetime(%NaiveDateTime{} = value) do
    case DateTime.from_naive(value, "Etc/UTC") do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      {:error, _reason} -> nil
    end
  end

  defp normalize_remote_datetime(_value), do: nil

  defp persist_snapshot(context, event, attendees, total_count) do
    with :ok <- authority_check(context.guard, context.event_id),
         :ok <- invoke_owner_write_hook(context, :attendee_snapshot),
         {:ok, processed_count} <-
           persist_attendees_under_owner(context, event.id, attendees),
         :ok <- post_response_fence(context),
         {:ok, _completed} <-
           SyncRun.complete(
             event.id,
             context.run.sync_run_id,
             context.run.owner_token,
             processed_count,
             context.pages
           ) do
      clear_owned_state(context)
      invalidate_sync_caches(event.id)
      {:ok, "Synced #{processed_count} attendees from #{total_count} Tickera tickets"}
    else
      {:error, :authority_revoked} -> finish_cancel(context, :authority_revoked)
      {:error, reason} -> finish_failure(context, safe_failure_reason(reason))
    end
  end

  defp persist_attendees_under_owner(context, event_id, attendees) do
    SyncRun.with_owned_write(
      event_id,
      context.run.sync_run_id,
      context.run.owner_token,
      fn locked_event, _run ->
        if context.incremental do
          attendees =
            Events.Sync.incremental_attendees_for_sync(
              locked_event.id,
              attendees,
              locked_event.last_sync_at
            )

          case Attendees.create_bulk(locked_event.id, attendees,
                 incremental: true,
                 skip_inner_transaction: true
               ) do
            {:ok, count} ->
              Events.bump_event_sync_version!(locked_event.id)
              count

            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          imported_codes =
            attendees
            |> Enum.map(&(TickeraClient.parse_attendee(&1) |> Map.get(:ticket_code)))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          case Attendees.create_bulk(locked_event.id, attendees,
                 incremental: false,
                 skip_inner_transaction: true
               ) do
            {:ok, count} ->
              :ok =
                Reconciliation.apply_after_authoritative_snapshot(
                  locked_event.id,
                  imported_codes,
                  context.run.sync_run_id
                )

              count

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end
      end
    )
  end

  defp extract_page(response) do
    {rows, _additional} = TickeraClient.extract_ticket_page(response)
    {:ok, rows}
  end

  defp extract_total_tickets(essentials) when is_map(essentials) do
    essentials
    |> Map.get("total_tickets", Map.get(essentials, :total_tickets))
    |> case do
      nil ->
        Map.get(essentials, "sold_tickets") || Map.get(essentials, :sold_tickets)

      total_tickets ->
        total_tickets
    end
    |> normalize_non_negative_integer()
  end

  defp normalize_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_negative_integer(value) when is_integer(value), do: 0
  defp normalize_non_negative_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp normalize_non_negative_integer(value) when is_float(value), do: 0

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} when parsed >= 0 -> parsed
      {parsed, _rest} when parsed < 0 -> 0
      :error -> nil
    end
  end

  defp normalize_non_negative_integer(_value), do: nil

  defp finish_cancel(context, reason) do
    _ = SyncRun.cancel(context.event_id, context.run.sync_run_id, context.run.owner_token, reason)
    clear_owned_state(context)
    {:error, reason}
  end

  defp finish_failure(context, reason) do
    _ =
      SyncRun.fail(
        context.event_id,
        context.run.sync_run_id,
        context.run.owner_token,
        :worker_failed,
        context.pages
      )

    clear_owned_state(context)
    {:error, reason}
  end

  defp clear_owned_state(context) do
    SyncState.clear_state(context.event_id, context.run.sync_run_id, context.run.owner_token)
  end

  defp invalidate_sync_caches(event_id) do
    _ = Cache.invalidate_event_cache(event_id)
    _ = Cache.invalidate_events_list_cache()
    _ = Stats.invalidate_event_stats_cache(event_id)
    _ = Stats.invalidate_occupancy_cache(event_id)
    stats = Stats.get_event_stats(event_id)
    Stats.broadcast_event_stats(event_id, stats)
  end

  defp invoke_callback(callback, page, total_pages, count) when is_function(callback, 3) do
    callback.(page, total_pages, count)
  rescue
    _ -> :ok
  end

  defp invoke_callback(_callback, _page, _total_pages, _count), do: :ok

  defp validate_guard(guard) when is_function(guard, 1), do: :ok
  defp validate_guard(_), do: {:error, :authority_required}

  defp authority_check(guard, event_id) do
    case guard.(event_id) do
      :ok -> :ok
      _ -> {:error, :authority_revoked}
    end
  rescue
    _ -> {:error, :authority_revoked}
  catch
    _, _ -> {:error, :authority_revoked}
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      incremental = Keyword.get(opts, :incremental, false)
      max_attempts = Keyword.get(opts, :max_attempts, 3)
      before_owner_write = Keyword.get(opts, :before_owner_write)

      if is_boolean(incremental) and is_integer(max_attempts) and max_attempts > 0 and
           (is_nil(before_owner_write) or is_function(before_owner_write, 1)) do
        {:ok, incremental, max_attempts, before_owner_write}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp invoke_owner_write_hook(%{before_owner_write: nil}, _stage), do: :ok

  defp invoke_owner_write_hook(%{before_owner_write: hook}, stage) when is_function(hook, 1) do
    hook.(stage)
    :ok
  end

  defp safe_failure_reason(:authority_revoked), do: :authority_revoked
  defp safe_failure_reason(:paused), do: :paused
  defp safe_failure_reason(reason) when is_atom(reason), do: reason
  defp safe_failure_reason(_), do: :worker_failed
end
