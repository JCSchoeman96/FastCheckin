defmodule FastCheck.Cache.CacheSplitTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Cache.CacheManager
  alias FastCheck.Cache.EtsLayer
  alias FastCheck.Crypto
  alias FastCheck.Events.Cache
  alias FastCheck.Events.CheckInConfiguration
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  setup do
    :ok = EtsLayer.init()
    :ok = EtsLayer.flush_all()

    _ = CacheManager.reset()

    on_exit(fn ->
      :ok = EtsLayer.flush_all()
      _ = CacheManager.reset()
    end)

    :ok
  end

  test "event cache entries remain Event structs when ticket config cache is updated" do
    event = insert_event("Cache Split Event")
    assert :ok == Cache.persist_event_cache(event)

    assert {:ok, %Event{id: event_id}} = EtsLayer.get_event_config(event.id)
    assert event_id == event.id

    assert {:ok, true} =
             CacheManager.put_event_config(event.id, [%{ticket_type_id: 99, ticket_type: "VIP"}])

    assert {:ok, %Event{id: persisted_event_id}} = EtsLayer.get_event_config(event.id)
    assert persisted_event_id == event.id

    assert {:ok, %{records: records}} = EtsLayer.get_ticket_config(event.id)

    assert Enum.any?(records, fn record ->
             Map.get(record, :ticket_type_id) == 99 or Map.get(record, "ticket_type_id") == 99
           end)
  end

  test "ticket config cache reads do not overwrite event cache entries" do
    event = insert_event("Ticket Config Cache Event")
    config = insert_ticket_config(event.id, 101, "Gold")

    assert :ok == Cache.persist_event_cache(event)

    assert {:ok, %CheckInConfiguration{ticket_type_id: 101}} =
             CacheManager.cache_get_ticket_config(event.id, config.ticket_type_id)

    assert {:ok, %Event{id: persisted_event_id}} = EtsLayer.get_event_config(event.id)
    assert persisted_event_id == event.id
  end

  test "ticket config cache warm path avoids repeated DB fallback reads" do
    event = insert_event("Warm Path Event")
    _config = insert_ticket_config(event.id, 305, "Balcony")

    {_, first_query_count} =
      capture_repo_queries(fn ->
        CacheManager.cache_get_ticket_config(event.id, 305)
      end)

    {_, second_query_count} =
      capture_repo_queries(fn ->
        CacheManager.cache_get_ticket_config(event.id, 305)
      end)

    assert first_query_count >= 1
    assert second_query_count == 0
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "cache-split-test-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, _metadata, _config ->
        send(parent, {:repo_query, ref})
      end,
      nil
    )

    result = fun.()
    query_count = drain_query_messages(ref, 0)

    :telemetry.detach(handler_id)

    {result, query_count}
  end

  defp drain_query_messages(ref, count) do
    receive do
      {:repo_query, ^ref} -> drain_query_messages(ref, count + 1)
    after
      0 -> count
    end
  end

  defp insert_event(name) do
    api_key = "cache-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt("scanner-secret")

    %Event{}
    |> Event.changeset(%{
      name: name,
      site_url: "https://example.com",
      tickera_site_url: "https://example.com",
      tickera_api_key_encrypted: encrypted_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      mobile_access_secret_encrypted: encrypted_secret,
      status: "active"
    })
    |> Repo.insert!()
  end

  defp insert_ticket_config(event_id, ticket_type_id, ticket_type) do
    %CheckInConfiguration{}
    |> CheckInConfiguration.changeset(%{
      event_id: event_id,
      ticket_type_id: ticket_type_id,
      ticket_type: ticket_type,
      allowed_checkins: 1,
      allow_reentry: false,
      status: "active"
    })
    |> Repo.insert!()
  end
end
