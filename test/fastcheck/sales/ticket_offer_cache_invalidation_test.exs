defmodule FastCheck.Sales.TicketOfferCacheInvalidationTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias FastCheck.Cache.CacheManager
  alias FastCheck.Sales.TicketOffer

  @event_id 77_001

  test "offer mutations invalidate centralized event offer cache keys" do
    key = "sales:event:#{@event_id}:offers:active"
    assert {:ok, true} = CacheManager.put(key, %{cached: true}, ttl: :timer.minutes(10))
    assert {:ok, %{cached: true}} = CacheManager.get(key)

    actor = admin_actor([@event_id])

    created =
      TicketOffer
      |> Changeset.for_create(:create_offer, valid_offer_attrs(), actor: actor, authorize?: true)
      |> Ash.create!(authorize?: true)

    assert {:ok, nil} = CacheManager.get(key)

    assert {:ok, true} = CacheManager.put(key, %{cached: true}, ttl: :timer.minutes(10))

    _updated =
      created
      |> Changeset.for_update(:disable_sales, %{},
        actor: actor,
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    assert {:ok, nil} = CacheManager.get(key)
  end

  defp valid_offer_attrs do
    %{
      event_id: @event_id,
      name: "Cache Test Offer",
      ticket_type: "vip",
      price_cents: 5_000,
      currency: "ZAR",
      configured_quantity_available: 20,
      initial_quantity: 20,
      max_per_order: 2,
      sales_enabled: true,
      sales_channel: "whatsapp",
      starts_at: nil,
      ends_at: nil
    }
  end

  defp admin_actor(event_ids) do
    %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: event_ids}
  end
end
