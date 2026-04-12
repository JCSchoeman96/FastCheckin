defmodule FastCheck.Attendees.ReconciliationTest do
  use FastCheck.DataCase, async: true

  import Ecto.Query

  alias FastCheck.Attendees.{Attendee, AttendeeInvalidationEvent, ReasonCodes, Reconciliation}
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  describe "apply_after_authoritative_snapshot/3" do
    test "marks active attendees absent from import set as not_scannable with invalidation rows" do
      event = create_event(%{name: "reconcile-absent"})
      _keep = create_attendee(event, %{ticket_code: "KEEP-1"})
      absent = create_attendee(event, %{ticket_code: "ABSENT-1"})
      sync_run = Ecto.UUID.generate()

      Repo.transaction(fn ->
        assert :ok ==
                 Reconciliation.apply_after_authoritative_snapshot(event.id, ["KEEP-1"], sync_run)
      end)

      kept = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "KEEP-1")
      assert kept.scan_eligibility == "active"

      gone = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "ABSENT-1")
      assert gone.scan_eligibility == "not_scannable"
      assert gone.ineligibility_reason == ReasonCodes.source_missing_from_authoritative_sync()

      inv =
        Repo.one!(
          from(i in AttendeeInvalidationEvent,
            where: i.attendee_id == ^absent.id
          )
        )

      assert inv.reason_code == ReasonCodes.source_missing_from_authoritative_sync()
      assert inv.change_type == "ineligible"

      assert Repo.one!(from(e in Event, where: e.id == ^event.id, select: e.event_sync_version)) >=
               1
    end

    test "reactivates not_scannable ticket when it reappears in the authoritative import set" do
      event = create_event(%{name: "reconcile-reactivate"})

      _a =
        create_attendee(event, %{
          ticket_code: "BACK-1",
          scan_eligibility: "not_scannable",
          ineligibility_reason: "revoked"
        })

      sync_run = Ecto.UUID.generate()

      Repo.transaction(fn ->
        assert :ok ==
                 Reconciliation.apply_after_authoritative_snapshot(event.id, ["BACK-1"], sync_run)
      end)

      back = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "BACK-1")
      assert back.scan_eligibility == "active"
      assert back.ineligibility_reason == nil
    end
  end
end
