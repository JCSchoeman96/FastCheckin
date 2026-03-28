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

  describe "incremental_attendees_for_sync/3" do
    test "includes all attendees when there is no previous sync timestamp" do
      event = create_event()

      remote_attendees = [
        %{"checksum" => "EXISTING-1", "buyer_first" => "John"},
        %{"checksum" => "NEW-2", "buyer_first" => "Jane"}
      ]

      assert remote_attendees ==
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 nil
               )
    end

    test "includes existing attendee when sync-relevant fields changed remotely" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-1", payment_status: "pending"})

      remote_attendees = [
        %{
          "checksum" => "EXISTING-1",
          "buyer_first" => "John",
          "buyer_last" => "Doe",
          "payment_status" => "completed",
          "allowed_checkins" => 1,
          "custom_fields" => [["Buyer E-mail", "john.doe@example.com"]]
        }
      ]

      assert [%{"checksum" => "EXISTING-1"}] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end

    test "excludes existing attendee when sync-relevant fields are unchanged" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-2"})

      remote_attendees = [
        %{
          "checksum" => "EXISTING-2",
          "buyer_first" => "John",
          "buyer_last" => "Doe",
          "payment_status" => "completed",
          "allowed_checkins" => 1,
          "custom_fields" => [
            ["Ticket Type", "General Admission"],
            ["Buyer E-mail", "john.doe@example.com"]
          ]
        }
      ]

      assert [] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end

    test "includes new attendee not found locally" do
      event = create_event()
      _attendee = create_attendee(event, %{ticket_code: "EXISTING-3"})

      remote_attendees = [
        %{
          "checksum" => "NEW-1",
          "buyer_first" => "Jane",
          "buyer_last" => "Roe",
          "payment_status" => "completed",
          "allowed_checkins" => 2,
          "custom_fields" => [
            ["Ticket Type", "VIP"],
            ["Buyer E-mail", "jane.roe@example.com"]
          ]
        }
      ]

      assert [%{"checksum" => "NEW-1"}] =
               Sync.incremental_attendees_for_sync(
                 event.id,
                 remote_attendees,
                 DateTime.utc_now()
               )
    end
  end

  defp assert_exported(module, function, arity) do
    Code.ensure_loaded!(module)
    assert function_exported?(module, function, arity)
  end
end
