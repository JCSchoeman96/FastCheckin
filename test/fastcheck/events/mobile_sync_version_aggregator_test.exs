defmodule FastCheck.Events.MobileSyncVersionAggregatorTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Attendees
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Cache.CacheManager
  alias FastCheck.Events.Event
  alias FastCheck.Events.MobileSyncVersionAggregator
  alias FastCheck.Repo

  describe "after_attendees_created/3" do
    test "increments event_sync_version exactly once for an existing event" do
      event = create_event()

      assert :ok =
               MobileSyncVersionAggregator.after_attendees_created(event.id, [
                 "SALES-ONE",
                 "SALES-TWO"
               ])

      assert event_sync_version(event.id) == 1
    end

    test "returns explicit errors for invalid event and ticket inputs" do
      assert {:error, :invalid_event_id} =
               MobileSyncVersionAggregator.after_attendees_created(nil, ["SALES-ONE"])

      assert {:error, :invalid_event_id} =
               MobileSyncVersionAggregator.after_attendees_created(0, ["SALES-ONE"])

      assert {:error, :no_ticket_codes} =
               MobileSyncVersionAggregator.after_attendees_created(create_event().id, [])

      assert {:error, :no_ticket_codes} =
               MobileSyncVersionAggregator.after_attendees_created(create_event().id, [
                 " ",
                 nil
               ])
    end

    test "returns event_not_found without pretending the bump succeeded" do
      assert {:error, :event_not_found} =
               MobileSyncVersionAggregator.after_attendees_created(999_999_999, ["SALES-ONE"])
    end

    test "deduplicates ticket codes but only bumps once" do
      event = create_event()

      assert :ok =
               MobileSyncVersionAggregator.after_attendees_created(event.id, [
                 " SALES-DUPE ",
                 "SALES-DUPE",
                 "SALES-OTHER"
               ])

      assert event_sync_version(event.id) == 1
    end

    test "invalidates attendee event cache and attendee id caches through public facades" do
      event = create_event()
      first = create_attendee(event, %{ticket_code: "CACHE-ONE"})
      second = create_attendee(event, %{ticket_code: "CACHE-TWO"})

      assert initial_attendees = Attendees.get_attendees_by_event(event.id)
      assert length(initial_attendees) == 2
      assert :ok = Attendees.delete_attendee_id_cache(first.id)
      assert %Attendee{} = Attendees.get_attendee!(first.id)
      assert {:ok, %Attendee{}} = CacheManager.get("attendee:id:#{first.id}")

      inserted_later = create_attendee(event, %{ticket_code: "CACHE-THREE"})

      assert :ok =
               MobileSyncVersionAggregator.after_attendees_created(
                 event.id,
                 [inserted_later.ticket_code],
                 attendee_ids: [first.id, second.id]
               )

      refreshed_codes =
        event.id
        |> Attendees.get_attendees_by_event()
        |> Enum.map(& &1.ticket_code)

      assert inserted_later.ticket_code in refreshed_codes
      assert {:ok, nil} = CacheManager.get("attendee:id:#{first.id}")
    end

    test "logs cache invalidation failures safely and keeps the durable bump" do
      event = create_event()

      log =
        capture_log(fn ->
          assert :ok =
                   MobileSyncVersionAggregator.after_attendees_created(
                     event.id,
                     ["LOG-SAFE-TICKET"],
                     attendee_ids: [123],
                     cache_facade: FastCheck.Events.MobileSyncVersionAggregatorTest.FailingCache,
                     source: :test_source
                   )
        end)

      assert event_sync_version(event.id) == 1
      assert log =~ "Mobile sync cache invalidation failed"
      assert log =~ "event_id=#{event.id}"
      assert log =~ "ticket_count=1"
      assert log =~ "attendee_count=1"
      assert log =~ "source=test_source"
      refute log =~ "LOG-SAFE-TICKET"
    end
  end

  defp event_sync_version(event_id) do
    Repo.one!(from(e in Event, where: e.id == ^event_id, select: e.event_sync_version))
  end

  defmodule FailingCache do
    def invalidate_attendees_by_event_cache(_event_id), do: :error
    def delete_attendee_id_cache(_attendee_id), do: :error
  end
end
