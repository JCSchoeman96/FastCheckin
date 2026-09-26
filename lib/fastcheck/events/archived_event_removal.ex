defmodule FastCheck.Events.ArchivedEventRemoval do
  @moduledoc """
  Fail-closed permanent removal for archived events with no durable dependencies.

  Used by `FastCheck.Events.remove_archived_event/1` for admin cleanup (#437).
  Postgres row locks and restrictive foreign keys are the integrity backstop.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Attendees.{Attendee, AttendeeInvalidationEvent, CheckIn, CheckInSession}
  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.CheckIns.OfflineEventPackage
  alias FastCheck.Devices.DeviceSession
  alias FastCheck.Events.{Cache, Event, Stats}
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Events.SyncLog
  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo
  alias FastCheck.Scans.ScanAttempt
  alias FastCheck.Ticketing.Gate
  alias FastCheck.Ticketing.SyncCursor

  @persist_scan_batch_worker "FastCheck.Scans.Jobs.PersistScanBatchJob"
  # Durable queue states only; completed/discarded/cancelled jobs are not active persistence work.
  @active_oban_states ~w(available scheduled executing retryable)

  @type blocker_map :: %{atom() => pos_integer()}

  @blocker_sources [
    {Attendee, :attendees},
    {CheckIn, :check_ins},
    {CheckInSession, :check_in_sessions},
    {ScanAttempt, :scan_attempts},
    {MobileIdempotencyLog, :mobile_idempotency_log},
    {AttendeeInvalidationEvent, :attendee_invalidation_events},
    {SyncLog, :sync_logs},
    {CheckInConfiguration, :check_in_configurations},
    {Gate, :gates},
    {OfflineEventPackage, :offline_event_packages},
    {DeviceSession, :device_sessions},
    {SyncCursor, :sync_cursors},
    {"sales_ticket_offers", :sales_ticket_offers},
    {"sales_orders", :sales_orders}
  ]

  @spec remove(pos_integer()) ::
          {:ok, %{id: pos_integer(), name: String.t()}}
          | {:error, :not_found}
          | {:error, :event_not_archived}
          | {:error, {:dependencies_present, blocker_map()}}
          | {:error, :integrity_conflict}
  def remove(event_id) when is_integer(event_id) and event_id > 0 do
    Repo.transaction(fn -> remove_locked(event_id) end)
    |> normalize_transaction_result()
    |> tap_success()
  end

  defp remove_locked(event_id) do
    case lock_event(event_id) do
      nil ->
        Repo.rollback(:not_found)

      %Event{status: "archived", whatsapp_sales_enabled: false} = event ->
        delete_if_no_blockers(event)

      %Event{} ->
        Repo.rollback(:event_not_archived)
    end
  end

  defp delete_if_no_blockers(%Event{} = event) do
    blockers = dependency_blockers(event.id)

    if map_size(blockers) > 0 do
      Repo.rollback({:dependencies_present, blockers})
    else
      case safe_delete_event(event) do
        {:ok, deleted} -> deleted
        {:error, :integrity_conflict} -> Repo.rollback(:integrity_conflict)
        {:error, other} -> Repo.rollback(other)
      end
    end
  end

  @doc false
  @spec dependency_blockers(pos_integer()) :: blocker_map()
  def dependency_blockers(event_id) when is_integer(event_id) and event_id > 0 do
    table_blockers =
      @blocker_sources
      |> Enum.reduce(%{}, fn {source, key}, acc ->
        case count_for_event(source, event_id) do
          0 -> acc
          count -> Map.put(acc, key, count)
        end
      end)

    case count_pending_scan_persistence_jobs(event_id) do
      0 -> table_blockers
      count -> Map.put(table_blockers, :pending_scan_persistence_jobs, count)
    end
  end

  defp lock_event(event_id) do
    from(e in Event, where: e.id == ^event_id, lock: "FOR UPDATE")
    |> Repo.one()
  end

  defp count_for_event(source, event_id) when is_binary(source) do
    Repo.one!(from(r in source, where: r.event_id == ^event_id, select: count(r.id)))
  end

  defp count_for_event(schema_module, event_id) do
    Repo.aggregate(
      from(r in schema_module, where: r.event_id == ^event_id),
      :count,
      :id
    )
  end

  defp safe_delete_event(%Event{} = event) do
    case Repo.delete(event) do
      {:ok, deleted} ->
        {:ok, deleted}

      {:error, %Ecto.Changeset{} = changeset} ->
        if fk_constraint_violation?(changeset) do
          {:error, :integrity_conflict}
        else
          {:error, changeset}
        end
    end
  rescue
    error in [Ecto.ConstraintError] ->
      if error.type == :foreign_key do
        {:error, :integrity_conflict}
      else
        reraise error, __STACKTRACE__
      end

    error in [Postgrex.Error] ->
      if postgrex_fk_violation?(error) do
        {:error, :integrity_conflict}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp count_pending_scan_persistence_jobs(event_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT COUNT(*)::bigint
        FROM oban_jobs AS j
        WHERE j.worker = $1
          AND j.state::text = ANY($2::text[])
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(j.args->'results') AS elem
            WHERE (elem->>'event_id')::bigint = $3
          )
        """,
        [@persist_scan_batch_worker, @active_oban_states, event_id]
      )

    count
  end

  defp fk_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :foreign_key
      _ -> false
    end)
  end

  defp postgrex_fk_violation?(%Postgrex.Error{postgres: %{code: :foreign_key_violation}}),
    do: true

  defp postgrex_fk_violation?(_), do: false

  defp normalize_transaction_result({:ok, %Event{id: id, name: name}}) do
    {:ok, %{id: id, name: name}}
  end

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_transaction_result({:ok, other}), do: {:error, other}

  defp tap_success({:ok, %{id: event_id, name: name}} = result) do
    invalidate_event_caches(event_id)

    Logger.info(fn ->
      [action: "remove_archived_event", outcome: "success", event_id: event_id, event_name: name]
    end)

    result
  end

  defp tap_success({:error, {:dependencies_present, blockers}} = result) do
    Logger.info(fn ->
      [
        action: "remove_archived_event",
        outcome: "blocked_dependencies",
        blocker_categories: Map.keys(blockers)
      ]
    end)

    result
  end

  defp tap_success({:error, reason} = result)
       when reason in [:integrity_conflict, :event_not_archived] do
    Logger.info(fn ->
      [action: "remove_archived_event", outcome: "blocked", reason: reason]
    end)

    result
  end

  defp tap_success(other), do: other

  defp invalidate_event_caches(event_id) do
    _ = Cache.invalidate_event_cache(event_id)
    _ = Cache.invalidate_events_list_cache()
    _ = Stats.invalidate_event_stats_cache(event_id)
    _ = Stats.invalidate_occupancy_cache(event_id)
    _ = CacheManager.invalidate_ticket_config(event_id)
    _ = EtsLayer.invalidate_attendees(event_id)
    _ = EtsLayer.invalidate_entrances(event_id)
  end
end
