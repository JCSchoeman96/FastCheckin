defmodule FastCheck.Events.WhatsAppQuantityCapTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.Events
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  setup do
    _ = Cache.invalidate_events_list_cache()
    _ = CacheManager.reset()
    EtsLayer.flush_all()

    on_exit(fn ->
      _ = CacheManager.reset()
      EtsLayer.flush_all()
    end)

    :ok
  end

  test "new events default to a WhatsApp quantity cap of 9" do
    event = create_event(%{name: "Quantity default"})

    assert 9 ==
             Repo.one(
               from e in Event,
                 where: e.id == ^event.id,
                 select: e.whatsapp_max_tickets_per_order
             )
  end

  test "positive cap can be changed explicitly" do
    event = create_event(%{name: "Quantity change"})
    assert {:ok, updated} = Events.set_whatsapp_max_tickets_per_order(event.id, 4)
    assert updated.whatsapp_max_tickets_per_order == 4
    assert Events.whatsapp_max_tickets_per_order(event.id) == 4
  end

  test "same-value update is idempotent and does not fake updated_at" do
    event = create_event(%{name: "Quantity no-op"})
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 3)

    old_timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3_600, :second)
      |> NaiveDateTime.truncate(:second)

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, unchanged} = Events.set_whatsapp_max_tickets_per_order(event.id, 3)
    assert unchanged.whatsapp_max_tickets_per_order == 3
    assert unchanged.updated_at == old_timestamp
  end

  test "real cap change updates updated_at" do
    event = create_event(%{name: "Quantity timestamp"})

    old_timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3_600, :second)
      |> NaiveDateTime.truncate(:second)

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, updated} = Events.set_whatsapp_max_tickets_per_order(event.id, 5)
    assert NaiveDateTime.compare(updated.updated_at, old_timestamp) == :gt
  end

  test "archived events cannot change the cap" do
    event = create_event(%{name: "Quantity archive"})
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 4)
    assert {:ok, archived} = Events.archive_event(event.id)
    assert archived.whatsapp_max_tickets_per_order == 4
    assert {:error, :event_archived} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)
  end

  test "archive preserves configured cap" do
    event = create_event(%{name: "Quantity archive preserve"})
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 6)
    assert {:ok, archived} = Events.archive_event(event.id)
    assert archived.whatsapp_max_tickets_per_order == 6
  end

  test "unarchive preserves configured cap" do
    event = create_event(%{name: "Quantity unarchive preserve"})
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 7)
    assert {:ok, archived} = Events.archive_event(event.id)
    assert archived.whatsapp_max_tickets_per_order == 7
    assert {:ok, active} = Events.unarchive_event(event.id)
    assert active.whatsapp_max_tickets_per_order == 7
  end

  test "real cap changes invalidate per-event and list caches" do
    Repo.delete_all(Event)
    _ = Cache.invalidate_events_list_cache()
    event = create_event(%{name: "Quantity cache"})
    assert :ok = FastCheck.Events.Cache.persist_event_cache(event)
    assert [_event] = Events.list_events()
    assert {:ok, _events} = CacheManager.get("events:all")

    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 2)
    assert :not_found == EtsLayer.get_event_config(event.id)
    assert {:ok, nil} = CacheManager.get("event_config:#{event.id}")
    assert {:ok, nil} = CacheManager.get("events:all")
  end

  test "generic event changesets do not mass assign the cap" do
    event = create_event(%{name: "Quantity changeset"})

    changeset = Event.changeset(event, %{whatsapp_max_tickets_per_order: 3})

    refute Ecto.Changeset.get_change(changeset, :whatsapp_max_tickets_per_order)
    assert {:ok, unchanged} = Repo.update(changeset)
    assert unchanged.whatsapp_max_tickets_per_order == 9
  end

  test "database CHECK rejects zero or negative direct persistence" do
    event = create_event(%{name: "Quantity constraint"})

    assert_raise Postgrex.Error, ~r/events_whatsapp_max_tickets_per_order_positive/, fn ->
      Repo.query!(
        "UPDATE events SET whatsapp_max_tickets_per_order = 0 WHERE id = $1",
        [event.id]
      )
    end

    changeset = Event.whatsapp_max_tickets_per_order_changeset(event, 0)
    assert {:error, failed} = Repo.update(changeset)
    assert Keyword.has_key?(failed.errors, :whatsapp_max_tickets_per_order)
  end

  test "domain setter accepts a positive value greater than 9" do
    event = create_event(%{name: "Quantity future"})
    assert {:ok, updated} = Events.set_whatsapp_max_tickets_per_order(event.id, 12)
    assert updated.whatsapp_max_tickets_per_order == 12
  end

  defp set_updated_at!(event_id, timestamp) do
    assert {1, nil} =
             Repo.update_all(
               from(e in Event, where: e.id == ^event_id),
               set: [updated_at: timestamp]
             )
  end
end
