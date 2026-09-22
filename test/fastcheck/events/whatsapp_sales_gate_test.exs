defmodule FastCheck.Events.WhatsAppSalesGateTest do
  use FastCheck.DataCase, async: false

  @moduletag skip_sales_event_anchors: true

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

  test "real gate and lifecycle transitions update updated_at without fake no-op changes" do
    event = create_event(%{name: "Gate timestamps"})

    old_timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.add(-3_600, :second)
      |> NaiveDateTime.truncate(:second)

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, enabled} = Events.enable_whatsapp_sales(event.id)
    assert NaiveDateTime.compare(enabled.updated_at, old_timestamp) == :gt

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, enabled_again} = Events.enable_whatsapp_sales(event.id)
    assert enabled_again.updated_at == old_timestamp

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, disabled} = Events.disable_whatsapp_sales(event.id)
    assert NaiveDateTime.compare(disabled.updated_at, old_timestamp) == :gt

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, disabled_again} = Events.disable_whatsapp_sales(event.id)
    assert disabled_again.updated_at == old_timestamp

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, archived} = Events.archive_event(event.id)
    assert archived.status == "archived"
    assert NaiveDateTime.compare(archived.updated_at, old_timestamp) == :gt

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, archived_again} = Events.archive_event(event.id)
    assert archived_again.updated_at == old_timestamp

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, unarchived} = Events.unarchive_event(event.id)
    assert unarchived.status == "active"
    assert NaiveDateTime.compare(unarchived.updated_at, old_timestamp) == :gt

    set_updated_at!(event.id, old_timestamp)
    assert {:ok, unarchived_again} = Events.unarchive_event(event.id)
    assert unarchived_again.updated_at == old_timestamp
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
    isolate_events_for_list_cache_test!()
    event = create_event(%{name: "Gate cache"})
    assert :ok = Cache.persist_event_cache(event)
    assert [_event] = Events.list_events()
    assert {:ok, _events} = CacheManager.get("events:all")

    assert {:ok, _} = Events.enable_whatsapp_sales(event.id)
    assert :not_found == EtsLayer.get_event_config(event.id)
    assert {:ok, nil} = CacheManager.get("event_config:#{event.id}")
    assert {:ok, nil} = CacheManager.get("events:all")

    assert :ok = Cache.persist_event_cache(event)
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

  test "generic archive changes report the gate invariant as a safe error" do
    event = create_event(%{name: "Gate changeset constraint"})
    assert {:ok, _enabled} = Events.enable_whatsapp_sales(event.id)

    assert {:error, failed_changeset} =
             Events.update_event(event.id, %{"status" => "archived"})

    assert Keyword.has_key?(failed_changeset.errors, :status)

    persisted = Repo.get!(Event, event.id)
    assert persisted.status == "active"
    assert persisted.whatsapp_sales_enabled
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

  defp set_updated_at!(event_id, timestamp) do
    assert {1, nil} =
             Repo.update_all(
               from(e in Event, where: e.id == ^event_id),
               set: [updated_at: timestamp]
             )
  end

  defp isolate_events_for_list_cache_test! do
    Repo.delete_all(Event)
    _ = Cache.invalidate_events_list_cache()
    _ = CacheManager.reset()
    EtsLayer.flush_all()
  end
end
