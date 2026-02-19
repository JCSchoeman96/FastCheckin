defmodule FastCheck.AttendeesBulkTest do
  use FastCheck.DataCase

  alias FastCheck.Attendees
  alias FastCheck.Events

  describe "bulk_check_in/2" do
    setup do
      event = create_event()
      attendee = create_attendee(event, %{ticket_code: "TICKET-1", allowed_checkins: 1})
      attendee2 = create_attendee(event, %{ticket_code: "TICKET-2", allowed_checkins: 1})

      %{event: event, attendees: [attendee, attendee2]}
    end

    test "processes multiple valid scans successfully", %{event: event} do
      scans = [
        %{
          "ticket_code" => "TICKET-1",
          "entrance_name" => "Main",
          "scanned_at" => DateTime.utc_now()
        },
        %{
          "ticket_code" => "TICKET-2",
          "entrance_name" => "VIP",
          "scanned_at" => DateTime.utc_now()
        }
      ]

      assert {:ok, results} = Attendees.bulk_check_in(event.id, scans)
      assert length(results) == 2

      assert Enum.all?(results, fn r -> r.status == "SUCCESS" end)

      # Verify DB updates
      assert Attendees.get_attendee(event.id, "TICKET-1").checked_in_at
      assert Attendees.get_attendee(event.id, "TICKET-2").checked_in_at
    end

    test "handles mixed valid and invalid scans", %{event: event} do
      scans = [
        %{"ticket_code" => "TICKET-1", "entrance_name" => "Main"},
        %{"ticket_code" => "INVALID-CODE", "entrance_name" => "Main"}
      ]

      assert {:ok, results} = Attendees.bulk_check_in(event.id, scans)
      assert length(results) == 2

      success = Enum.find(results, &(&1.ticket_code == "TICKET-1"))
      assert success.status == "SUCCESS"

      failure = Enum.find(results, &(&1.ticket_code == "INVALID-CODE"))
      assert failure.status == "ERROR"
      assert failure.error_code == "INVALID"
    end
  end
end
