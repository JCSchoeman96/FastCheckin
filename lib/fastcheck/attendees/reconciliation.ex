defmodule FastCheck.Attendees.Reconciliation do
  @moduledoc """
  Authoritative Tickera snapshot reconciliation: mark absent tickets not_scannable,
  reactivate on reappearance, append invalidation events, bump `event_sync_version` once per run.

  Called only after a **complete** authoritative fetch (full non-incremental sync). Must run inside
  the caller's `Repo.transaction/1`.
  """

  import Ecto.Query

  alias FastCheck.Attendees.{Attendee, AttendeeInvalidationEvent, ReasonCodes}
  alias FastCheck.Events
  alias FastCheck.Repo

  @eligibility_active "active"
  @eligibility_not_scannable "not_scannable"
  @change_type_ineligible "ineligible"

  @doc """
  Normalizes ticket codes for consistent set comparison (matches Tickera import uniqueness).
  """
  @spec normalize_ticket_code(String.t() | nil) :: String.t() | nil
  def normalize_ticket_code(nil), do: nil

  def normalize_ticket_code(code) when is_binary(code) do
    code |> String.trim() |> then(fn c -> if c == "", do: nil, else: c end)
  end

  @doc """
  Applies post-import reconciliation after a complete authoritative snapshot.
  `imported_ticket_codes` must be the full set of ticket codes returned by Tickera for this event.
  """
  @spec apply_after_authoritative_snapshot(integer(), [String.t()], Ecto.UUID.t()) ::
          :ok | {:error, term()}
  def apply_after_authoritative_snapshot(event_id, imported_ticket_codes, sync_run_id)
      when is_integer(event_id) and is_list(imported_ticket_codes) do
    imported =
      imported_ticket_codes
      |> Enum.map(&normalize_ticket_code/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    imported_list = MapSet.to_list(imported)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    naive_now = DateTime.to_naive(now)

    mark_imported_seen(event_id, imported_list, sync_run_id, now, naive_now)
    reactivate_imported(event_id, imported_list, naive_now)
    mark_absent_not_scannable(event_id, imported_list, sync_run_id, now, naive_now)
    Events.bump_event_sync_version!(event_id)
    :ok
  end

  defp mark_imported_seen(_event_id, [], _sync_run_id, _now, _naive_now), do: {0, nil}

  defp mark_imported_seen(event_id, imported_list, sync_run_id, now, naive_now) do
    q =
      from(a in Attendee,
        where: a.event_id == ^event_id and a.ticket_code in ^imported_list
      )

    Repo.update_all(q,
      set: [
        source_last_seen_at: now,
        last_authoritative_sync_run_id: sync_run_id,
        updated_at: naive_now
      ]
    )
  end

  defp reactivate_imported(_event_id, [], _naive_now), do: {0, nil}

  defp reactivate_imported(event_id, imported_list, naive_now) do
    q =
      from(a in Attendee,
        where:
          a.event_id == ^event_id and a.ticket_code in ^imported_list and
            a.scan_eligibility == ^@eligibility_not_scannable
      )

    Repo.update_all(q,
      set: [
        scan_eligibility: @eligibility_active,
        ineligibility_reason: nil,
        ineligible_since: nil,
        updated_at: naive_now
      ]
    )
  end

  defp mark_absent_not_scannable(event_id, imported_list, sync_run_id, now, naive_now) do
    absent_query =
      if imported_list == [] do
        from(a in Attendee,
          where: a.event_id == ^event_id and a.scan_eligibility == ^@eligibility_active
        )
      else
        from(a in Attendee,
          where:
            a.event_id == ^event_id and a.scan_eligibility == ^@eligibility_active and
              a.ticket_code not in ^imported_list
        )
      end

    absent =
      absent_query
      |> select([a], {a.id, a.ticket_code})
      |> Repo.all()

    reason = ReasonCodes.source_missing_from_authoritative_sync()

    Enum.each(absent, fn {attendee_id, ticket_code} ->
      {:ok, _} =
        %AttendeeInvalidationEvent{}
        |> AttendeeInvalidationEvent.changeset(%{
          event_id: event_id,
          attendee_id: attendee_id,
          ticket_code: ticket_code,
          change_type: @change_type_ineligible,
          reason_code: reason,
          effective_at: now,
          source_sync_run_id: sync_run_id
        })
        |> Ecto.Changeset.put_change(:inserted_at, naive_now)
        |> Repo.insert()
    end)

    absent_ids = Enum.map(absent, fn {id, _} -> id end)

    if absent_ids != [] do
      q = from(a in Attendee, where: a.id in ^absent_ids)

      Repo.update_all(q,
        set: [
          scan_eligibility: @eligibility_not_scannable,
          ineligibility_reason: reason,
          ineligible_since: now,
          updated_at: naive_now
        ]
      )
    end

    :ok
  end
end
