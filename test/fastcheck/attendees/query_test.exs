defmodule FastCheck.Attendees.QueryTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Query

  describe "module exports" do
    test "exports list_event_attendees/1" do
      assert_exported(Query, :list_event_attendees, 1)
    end

    test "exports search_event_attendees/3" do
      assert_exported(Query, :search_event_attendees, 3)
    end

    test "exports get_attendee_by_ticket_code/2" do
      assert_exported(Query, :get_attendee_by_ticket_code, 2)
    end

    test "exports fetch_attendee_for_update/2" do
      assert_exported(Query, :fetch_attendee_for_update, 2)
    end

    test "exports compute_occupancy_breakdown/1" do
      assert_exported(Query, :compute_occupancy_breakdown, 1)
    end

    test "exports get_event_stats/1" do
      assert_exported(Query, :get_event_stats, 1)
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
