defmodule FastCheck.Attendees.QueryTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Query

  describe "module exports" do
    test "exports list_event_attendees/1" do
      assert function_exported?(Query, :list_event_attendees, 1)
    end

    test "exports search_event_attendees/3" do
      assert function_exported?(Query, :search_event_attendees, 3)
    end

    test "exports get_attendee_by_ticket_code/2" do
      assert function_exported?(Query, :get_attendee_by_ticket_code, 2)
    end

    test "exports fetch_attendee_for_update/2" do
      assert function_exported?(Query, :fetch_attendee_for_update, 2)
    end

    test "exports compute_occupancy_breakdown/1" do
      assert function_exported?(Query, :compute_occupancy_breakdown, 1)
    end

    test "exports get_event_stats/1" do
      assert function_exported?(Query, :get_event_stats, 1)
    end
  end
end
