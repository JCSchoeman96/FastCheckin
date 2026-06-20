defmodule FastCheck.Attendees.ScanTest do
  use FastCheck.DataCase, async: true

  import FastCheck.Fixtures

  alias FastCheck.Attendees.Scan

  describe "check_in/4" do
    test "accepts active fastcheck_sales attendees through existing scanner path" do
      event = create_event()

      _attendee =
        create_attendee(event, %{
          ticket_code: "SALES-ACTIVE-1",
          source: "fastcheck_sales",
          source_reference: "sales:#{System.unique_integer([:positive])}:1:1",
          payment_status: "completed",
          scan_eligibility: "active",
          allowed_checkins: 1,
          checkins_remaining: 1
        })

      assert {:ok, attendee, "SUCCESS"} =
               Scan.check_in(event.id, "SALES-ACTIVE-1", "Main", nil)

      assert attendee.source == "fastcheck_sales"
      assert attendee.checkins_remaining == 0
    end

    test "rejects not_scannable tickets with TICKET_NOT_SCANNABLE" do
      event = create_event()

      _attendee =
        create_attendee(event, %{ticket_code: "REVOKED-1", scan_eligibility: "not_scannable"})

      assert {:error, "TICKET_NOT_SCANNABLE", _msg} =
               Scan.check_in(event.id, "REVOKED-1", "Main", nil)
    end
  end

  describe "module exports" do
    test "exports check_in/4" do
      assert_exported(Scan, :check_in, 4)
    end

    test "exports check_in_advanced/5" do
      assert_exported(Scan, :check_in_advanced, 5)
    end

    test "exports bulk_check_in/2" do
      assert_exported(Scan, :bulk_check_in, 2)
    end

    test "exports check_out/4" do
      assert_exported(Scan, :check_out, 4)
    end

    test "exports reset_scan_counters/2" do
      assert_exported(Scan, :reset_scan_counters, 2)
    end

    test "exports mark_manual_entry/5" do
      assert_exported(Scan, :mark_manual_entry, 5)
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
