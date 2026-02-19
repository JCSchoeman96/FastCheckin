defmodule FastCheck.Events.SyncTest do
  use FastCheck.DataCase, async: true

  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Events.Sync

  describe "module exports" do
    test "exports sync_event/3" do
      assert_exported(Sync, :sync_event, 3)
    end

    test "exports get_tickera_api_key/1" do
      assert_exported(Sync, :get_tickera_api_key, 1)
    end

    test "exports touch_last_sync/1" do
      assert_exported(Sync, :touch_last_sync, 1)
    end

    test "exports touch_last_soft_sync/1" do
      assert_exported(Sync, :touch_last_soft_sync, 1)
    end
  end

  describe "get_tickera_api_key/1" do
    test "returns a normalized decrypted key" do
      {:ok, encrypted} = Crypto.encrypt(" 5CC0A15C \n")
      event = %Event{id: 123, tickera_api_key_encrypted: encrypted}

      assert {:ok, "5CC0A15C"} = Sync.get_tickera_api_key(event)
    end

    test "returns error when decrypted key is blank" do
      {:ok, encrypted} = Crypto.encrypt("   ")
      event = %Event{id: 456, tickera_api_key_encrypted: encrypted}

      assert {:error, :decryption_failed} = Sync.get_tickera_api_key(event)
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
