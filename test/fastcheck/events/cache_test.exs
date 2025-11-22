defmodule FastCheck.Events.CacheTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Events.Cache

  describe "module exports" do
    test "exports list_events/0" do
      assert function_exported?(Cache, :list_events, 0)
    end

    test "exports get_event!/1" do
      assert function_exported?(Cache, :get_event!, 1)
    end

    test "exports persist_event_cache/1" do
      assert function_exported?(Cache, :persist_event_cache, 1)
    end

    test "exports invalidate_event_cache/1" do
      assert function_exported?(Cache, :invalidate_event_cache, 1)
    end

    test "exports invalidate_events_list_cache/0" do
      assert function_exported?(Cache, :invalidate_events_list_cache, 0)
    end
  end
end
