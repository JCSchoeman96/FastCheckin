defmodule FastCheck.Attendees.ScanTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Scan

  describe "module exports" do
    test "exports check_in/4" do
      assert function_exported?(Scan, :check_in, 4)
    end

    test "exports check_in_advanced/5" do
      assert function_exported?(Scan, :check_in_advanced, 5)
    end

    test "exports bulk_check_in/2" do
      assert function_exported?(Scan, :bulk_check_in, 2)
    end

    test "exports check_out/2" do
      assert function_exported?(Scan, :check_out, 2)
    end

    test "exports reset_scan_counters/1" do
      assert function_exported?(Scan, :reset_scan_counters, 1)
    end

    test "exports mark_manual_entry/2" do
      assert function_exported?(Scan, :mark_manual_entry, 2)
    end
  end
end
