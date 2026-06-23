defmodule FastCheck.Tickets.ScannerVisibilityTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.AttendeeInvalidationEvent
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Repo
  alias FastCheck.Tickets.ScannerVisibility

  test "mark_not_scannable sets attendee ineligible and appends invalidation" do
    event = create_event()
    attendee = create_attendee(event, %{ticket_code: "SV-1", scan_eligibility: "active"})

    assert {:ok, %{changed: true, invalidation_appended: true, attendee: updated}} =
             ScannerVisibility.mark_not_scannable(attendee)

    assert updated.scan_eligibility == "not_scannable"
    assert updated.ineligibility_reason == ReasonCodes.revoked()
    assert updated.ineligible_since

    invalidation =
      Repo.one!(
        from i in AttendeeInvalidationEvent,
          where: i.attendee_id == ^updated.id,
          order_by: [desc: i.id],
          limit: 1
      )

    assert invalidation.change_type == "ineligible"
    assert invalidation.reason_code == ReasonCodes.revoked()
  end

  test "mark_not_scannable is idempotent when already not_scannable" do
    event = create_event()

    attendee =
      create_attendee(event, %{
        ticket_code: "SV-2",
        scan_eligibility: "not_scannable",
        ineligibility_reason: ReasonCodes.revoked()
      })

    before_count = invalidation_count(attendee.id)

    assert {:ok, %{changed: false, invalidation_appended: false}} =
             ScannerVisibility.mark_not_scannable(attendee)

    assert invalidation_count(attendee.id) == before_count
  end

  defp invalidation_count(attendee_id) do
    Repo.one!(
      from i in AttendeeInvalidationEvent,
        where: i.attendee_id == ^attendee_id,
        select: count(i.id)
    )
  end
end
