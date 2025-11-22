defmodule FastCheck.Attendees.CacheTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Cache

  describe "module exports" do
    test "exports get_attendee_by_ticket_code/2" do
      assert function_exported?(Cache, :get_attendee_by_ticket_code, 2)
    end

    test "exports get_attendee!/2" do
      assert function_exported?(Cache, :get_attendee!, 2)
    end

    test "exports list_event_attendees/1" do
      assert function_exported?(Cache, :list_event_attendees, 1)
    end

    test "exports get_attendees_by_event/1" do
      assert function_exported?(Cache, :get_attendees_by_event, 1)
    end

    test "exports invalidate_attendees_by_event_cache/1" do
      assert function_exported?(Cache, :invalidate_attendees_by_event_cache, 1)
    end

    test "exports delete_attendee_id_cache/2" do
      assert function_exported?(Cache, :delete_attendee_id_cache, 2)
    end
  end
end
