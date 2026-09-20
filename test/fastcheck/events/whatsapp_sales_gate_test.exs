defmodule FastCheck.Events.WhatsAppSalesGateTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  setup do
    _ = CacheManager.reset()
    EtsLayer.flush_all()

    on_exit(fn ->
      _ = CacheManager.reset()
      EtsLayer.flush_all()
    end)

    :ok
  end

  test "new events default to disabled WhatsApp sales" do
    event = create_event(%{name: "Gate default"})

    assert false ==
             Repo.one(from e in Event, where: e.id == ^event.id, select: e.whatsapp_sales_enabled)
  end

  test "enable and disable are idempotent durable event operations" do
    event = create_event(%{name: "Gate transitions"})

    assert {:ok, enabled} = Events.enable_whatsapp_sales(event.id)
    assert enabled.whatsapp_sales_enabled
    assert Events.whatsapp_sales_enabled?(event.id)

    assert {:ok, enabled_again} = Events.enable_whatsapp_sales(event.id)
    assert enabled_again.whatsapp_sales_enabled

    assert {:ok, disabled} = Events.disable_whatsapp_sales(event.id)
    refute disabled.whatsapp_sales_enabled
    refute Events.whatsapp_sales_enabled?(event.id)

    assert {:ok, disabled_again} = Events.disable_whatsapp_sales(event.id)
    refute disabled_again.whatsapp_sales_enabled
  end

  test "archived events cannot be enabled and archive forces the gate off" do
    event = create_event(%{name: "Gate archive"})
    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)

    assert {:ok, archived} = Events.archive_event(event.id)
    assert archived.status == "archived"
    refute archived.whatsapp_sales_enabled
    refute Events.whatsapp_sales_enabled?(event.id)

    assert {:error, :event_archived} = Events.enable_whatsapp_sales(event.id)
    assert {:ok, archived_again} = Events.archive_event(event.id)
    assert archived_again.status == "archived"
    refute archived_again.whatsapp_sales_enabled

    assert {:ok, unarchived} = Events.unarchive_event(event.id)
    assert unarchived.status == "active"
    refute unarchived.whatsapp_sales_enabled
  end

  test "unarchive leaves WhatsApp sales disabled until explicitly enabled" do
    event = create_event(%{name: "Gate unarchive", status: "archived"})

    assert {:ok, active} = Events.unarchive_event(event.id)
    assert active.status == "active"
    refute active.whatsapp_sales_enabled
    refute Events.whatsapp_sales_enabled?(event.id)
  end

  test "gate operations invalidate the per-event and list caches" do
    event = create_event(%{name: "Gate cache"})
    assert :ok = FastCheck.Events.Cache.persist_event_cache(event)
    assert [_event] = Events.list_events()
    assert {:ok, _events} = CacheManager.get("events:all")

    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert :not_found == EtsLayer.get_event_config(event.id)
    assert {:ok, nil} = CacheManager.get("event_config:#{event.id}")
    assert {:ok, nil} = CacheManager.get("events:all")

    assert :ok = FastCheck.Events.Cache.persist_event_cache(event)
    assert [_event] = Events.list_events()
    assert {:ok, _events} = CacheManager.get("events:all")

    assert {:ok, _} = Events.disable_whatsapp_sales(event.id)
    assert :not_found == EtsLayer.get_event_config(event.id)
    assert {:ok, nil} = CacheManager.get("event_config:#{event.id}")
    assert {:ok, nil} = CacheManager.get("events:all")
  end

  test "generic event changesets do not mass assign the gate" do
    event = create_event(%{name: "Gate changeset"})

    changeset = Event.changeset(event, %{whatsapp_sales_enabled: true})

    refute Ecto.Changeset.get_change(changeset, :whatsapp_sales_enabled)
    assert {:ok, unchanged} = Repo.update(changeset)
    refute unchanged.whatsapp_sales_enabled
  end

  test "the database rejects archived events with the gate enabled" do
    event = create_event(%{name: "Gate constraint"})

    assert_raise Postgrex.Error, ~r/events_whatsapp_sales_archived_invariant/, fn ->
      Repo.query!(
        "UPDATE events SET status = 'archived', whatsapp_sales_enabled = true WHERE id = $1",
        [event.id]
      )
    end
  end
end
