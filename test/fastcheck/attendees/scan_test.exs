defmodule FastCheck.Attendees.ScanTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Scan

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
