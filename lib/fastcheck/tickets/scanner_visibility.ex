defmodule FastCheck.Tickets.ScannerVisibility do
  @moduledoc """
  Sales-origin scanner visibility writes for revoked tickets.

  Updates existing FastCheck `Attendee` scan eligibility and appends
  `AttendeeInvalidationEvent` rows without mutating scanner core paths.
  """

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Repo

  @ineligible_status "not_scannable"
  @change_type_ineligible "ineligible"

  @type mark_result :: %{
          attendee: Attendee.t(),
          changed: boolean(),
          invalidation_appended: boolean()
        }

  @doc """
  Marks an attendee scanner-ineligible and appends an invalidation event when newly ineligible.

  When the attendee is already `not_scannable`, returns idempotent success without
  duplicate attendee mutation or invalidation insert.
  """
  @spec mark_not_scannable(Attendee.t(), keyword()) :: {:ok, mark_result()}
  def mark_not_scannable(%Attendee{} = attendee, opts \\ []) do
    reason_code = opts |> Keyword.get(:reason_code) |> normalize_reason_code()
    source_sync_run_id = Keyword.get(opts, :source_sync_run_id)
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    if attendee.scan_eligibility == @ineligible_status do
      {:ok, %{attendee: attendee, changed: false, invalidation_appended: false}}
    else
      updated =
        attendee
        |> Attendee.changeset(%{
          scan_eligibility: @ineligible_status,
          ineligibility_reason: reason_code,
          ineligible_since: now
        })
        |> Repo.update!()

      %AttendeeInvalidationEvent{}
      |> AttendeeInvalidationEvent.changeset(%{
        event_id: updated.event_id,
        attendee_id: updated.id,
        ticket_code: updated.ticket_code,
        change_type: @change_type_ineligible,
        reason_code: reason_code,
        effective_at: now,
        source_sync_run_id: source_sync_run_id
      })
      |> Repo.insert!()

      {:ok,
       %{
         attendee: updated,
         changed: true,
         invalidation_appended: true
       }}
    end
  end

  defp normalize_reason_code(nil), do: ReasonCodes.revoked()
  defp normalize_reason_code(code) when is_binary(code), do: code
  defp normalize_reason_code(code) when is_atom(code), do: Atom.to_string(code)
end
