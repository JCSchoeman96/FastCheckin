defmodule FastCheck.Events.SyncTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Events.Sync

  describe "module exports" do
    test "exports sync_event/2" do
      assert function_exported?(Sync, :sync_event, 2)
    end

    test "exports get_tickera_api_key/1" do
      assert function_exported?(Sync, :get_tickera_api_key, 1)
    end

    test "exports touch_last_sync/1" do
      assert function_exported?(Sync, :touch_last_sync, 1)
    end

    test "exports touch_last_soft_sync/1" do
      assert function_exported?(Sync, :touch_last_soft_sync, 1)
    end
  end
end
