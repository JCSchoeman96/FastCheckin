defmodule FastCheck.Attendees.CacheTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Attendees.Cache

  describe "module exports" do
    test "exports get_attendee_by_ticket_code/2" do
      assert_exported(Cache, :get_attendee_by_ticket_code, 2)
    end

    test "exports get_attendee!/1" do
      assert_exported(Cache, :get_attendee!, 1)
    end

    test "exports list_event_attendees/1" do
      assert_exported(Cache, :list_event_attendees, 1)
    end

    test "exports get_attendees_by_event/2" do
      assert_exported(Cache, :get_attendees_by_event, 2)
    end

    test "exports invalidate_attendees_by_event_cache/1" do
      assert_exported(Cache, :invalidate_attendees_by_event_cache, 1)
    end

    test "exports delete_attendee_id_cache/1" do
      assert_exported(Cache, :delete_attendee_id_cache, 1)
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
