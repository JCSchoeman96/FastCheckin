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
         {:ok, incremental, max_attempts} <- validate_options(opts),
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
         {:ok, attendees, page_count} <- fetch_pages(context, event, api_key, 1, [], 0) do
      persist_snapshot(context, event, attendees, page_count)
    else
      {:error, :authority_revoked} -> finish_cancel(context, :authority_revoked)
      {:error, :paused} -> {:error, :paused}
      {:error, :stale_owner} -> {:error, :stale_owner}
      {:error, reason} -> finish_failure(context, safe_failure_reason(reason))
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

    with {:ok, response} <- result,
         {:ok, rows} <- extract_page(response),
         next_count = count + length(rows),
         {:ok, next_context} <- record_progress(context, page, next_count) do
      next_acc = Enum.reverse(rows, acc)

      if length(rows) == @per_page do
        fetch_pages(next_context, event, api_key, page + 1, next_acc, next_count)
      else
        {:ok, Enum.reverse(next_acc), next_count}
      end
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

  defp persist_event_essentials(context, event, essentials) do
    with :ok <- post_response_fence(context) do
      total = extract_total_tickets(essentials)
      start_date = normalize_remote_datetime(Map.get(essentials, "event_start_date"))
      end_date = normalize_remote_datetime(Map.get(essentials, "event_end_date"))

      attrs =
        [total_tickets: total, tickera_start_date: start_date, tickera_end_date: end_date]
        |> Enum.reject(fn
          {:total_tickets, nil} -> true
          {_field, nil} -> true
          {field, value} -> Map.get(event, field) == value
        end)
        |> Map.new()

      if map_size(attrs) > 0 do
        case event |> Event.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            _ = Cache.invalidate_event_cache(updated.id)
            _ = Cache.invalidate_events_list_cache()
            :ok

          {:error, _changeset} ->
            {:error, :worker_failed}
        end
      else
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
    case post_response_fence(context) do
      :ok ->
        to_write =
          if context.incremental do
            Events.Sync.incremental_attendees_for_sync(event.id, attendees, event.last_sync_at)
          else
            attendees
          end

        persisted =
          if context.incremental do
            case Attendees.create_bulk(event.id, to_write, incremental: true) do
              {:ok, count} ->
                Events.bump_event_sync_version!(event.id)
                {:ok, count}

              {:error, reason} ->
                {:error, reason}
            end
          else
            imported_codes =
              attendees
              |> Enum.map(&(TickeraClient.parse_attendee(&1) |> Map.get(:ticket_code)))
              |> Enum.reject(&is_nil/1)
              |> Enum.uniq()

            persist_authoritative_snapshot(
              event.id,
              to_write,
              imported_codes,
              context.run.sync_run_id
            )
          end

        with {:ok, processed_count} <- persisted,
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

      {:error, :authority_revoked} ->
        finish_cancel(context, :authority_revoked)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_authoritative_snapshot(event_id, attendees, imported_codes, sync_run_id) do
    Repo.transaction(fn ->
      case Attendees.create_bulk(event_id, attendees,
             incremental: false,
             skip_inner_transaction: true
           ) do
        {:ok, count} ->
          :ok =
            Reconciliation.apply_after_authoritative_snapshot(
              event_id,
              imported_codes,
              sync_run_id
            )

          count

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp extract_page(%{} = response) do
    data = Map.get(response, "data", Map.get(response, :data))

    rows =
      case data do
        list when is_list(list) -> Enum.map(list, &extract_ticket/1)
        map when is_map(map) -> [extract_ticket(map)]
        _ -> []
      end

    {:ok, Enum.reject(rows, &(&1 == %{}))}
  end

  defp extract_page(response) when is_list(response) do
    rows =
      response
      |> Enum.flat_map(fn
        %{"data" => %{} = row} -> [row]
        %{data: %{} = row} -> [row]
        %{} = row -> [row]
        _ -> []
      end)

    {:ok, rows}
  end

  defp extract_page(_), do: {:error, :invalid_response}

  defp extract_ticket(%{"data" => %{} = row}), do: row
  defp extract_ticket(%{data: %{} = row}), do: row
  defp extract_ticket(%{} = row), do: row
  defp extract_ticket(_), do: %{}

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

      if is_boolean(incremental) and is_integer(max_attempts) and max_attempts > 0 do
        {:ok, incremental, max_attempts}
      else
        {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  defp safe_failure_reason(:authority_revoked), do: :authority_revoked
  defp safe_failure_reason(:paused), do: :paused
  defp safe_failure_reason(reason) when is_atom(reason), do: reason
  defp safe_failure_reason(_), do: :worker_failed
end
