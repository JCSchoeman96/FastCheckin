defmodule FastCheck.Sales.TicketOfferTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.TicketOffer

  @event_id 12_001

  test "admin can create and update offers through named actions" do
    actor = admin_actor([@event_id])

    offer =
      TicketOffer
      |> Changeset.for_create(:create_offer, valid_offer_attrs(@event_id),
        actor: actor,
        authorize?: true
      )
      |> Ash.create!(authorize?: true)

    assert offer.event_id == @event_id
    assert offer.sales_enabled == true
    assert offer.starts_at == nil
    assert offer.ends_at == nil

    updated =
      offer
      |> Changeset.for_update(
        :update_offer,
        %{name: "VIP Updated"},
        actor: actor,
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    assert updated.name == "VIP Updated"
  end

  test "enable_sales and disable_sales are idempotent admin actions" do
    actor = admin_actor([@event_id])

    offer =
      insert_offer!(
        event_id: @event_id,
        sales_enabled: false
      )

    enabled =
      offer
      |> Changeset.for_update(:enable_sales, %{},
        actor: actor,
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    assert enabled.sales_enabled

    enabled_again =
      enabled
      |> Changeset.for_update(:enable_sales, %{},
        actor: actor,
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    assert enabled_again.sales_enabled

    disabled =
      enabled_again
      |> Changeset.for_update(:disable_sales, %{},
        actor: actor,
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    refute disabled.sales_enabled
  end

  test "create_offer rejects invalid currency and window values" do
    actor = admin_actor([@event_id])

    assert_raise Ash.Error.Invalid, fn ->
      TicketOffer
      |> Changeset.for_create(:create_offer, valid_offer_attrs(@event_id, %{currency: "zar"}),
        actor: actor,
        authorize?: true
      )
      |> Ash.create!(authorize?: true)
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    earlier = DateTime.add(now, -60, :second)

    assert_raise Ash.Error.Unknown, fn ->
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        valid_offer_attrs(@event_id, %{starts_at: now, ends_at: earlier}),
        actor: actor,
        authorize?: true
      )
      |> Ash.create!(authorize?: true)
    end
  end

  test "list_active_for_event filters by event, window, archived and channel" do
    actor = admin_actor([@event_id])
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    active = insert_offer!(event_id: @event_id, sales_channel: "whatsapp")
    _wrong_channel = insert_offer!(event_id: @event_id, sales_channel: "admin")
    _disabled = insert_offer!(event_id: @event_id, sales_enabled: false)
    _archived = insert_offer!(event_id: @event_id, archived_at: now)
    _other_event = insert_offer!(event_id: @event_id + 1, sales_channel: "whatsapp")
    _ended = insert_offer!(event_id: @event_id, ends_at: DateTime.add(now, -30, :second))
    _future = insert_offer!(event_id: @event_id, starts_at: DateTime.add(now, 300, :second))

    results =
      TicketOffer
      |> Query.for_read(
        :list_active_for_event,
        %{event_id: @event_id, sales_channel: "whatsapp", as_of: now},
        actor: actor,
        authorize?: true
      )
      |> Ash.read!(authorize?: true)

    assert Enum.map(results, & &1.id) == [active.id]
  end

  test "get_available_for_checkout only returns durable eligible offer" do
    actor = admin_actor([@event_id])
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    offer = insert_offer!(event_id: @event_id, sales_channel: "all")

    found =
      TicketOffer
      |> Query.for_read(
        :get_available_for_checkout,
        %{id: offer.id, event_id: @event_id, sales_channel: "whatsapp", as_of: now},
        actor: actor,
        authorize?: true
      )
      |> Ash.read_one!(authorize?: true)

    assert found.id == offer.id
  end

  defp valid_offer_attrs(event_id, overrides \\ %{}) do
    base = %{
      event_id: event_id,
      name: "VIP",
      ticket_type: "vip",
      price_cents: 12_500,
      currency: "ZAR",
      configured_quantity_available: 100,
      initial_quantity: 100,
      max_per_order: 4,
      sales_enabled: true,
      sales_channel: "whatsapp",
      starts_at: nil,
      ends_at: nil
    }

    Map.merge(base, overrides)
  end

  defp insert_offer!(opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    sales_channel = Keyword.get(opts, :sales_channel, "whatsapp")
    sales_enabled = Keyword.get(opts, :sales_enabled, true)
    starts_at = Keyword.get(opts, :starts_at)
    ends_at = Keyword.get(opts, :ends_at)
    archived_at = Keyword.get(opts, :archived_at)

    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, archived_at, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', 10000, 'ZAR', 100, 100, 2, $3, $4, $5, $6, 1, $7, now(), now())
        RETURNING id
        """,
        [
          event_id,
          "Offer-#{System.unique_integer([:positive])}",
          sales_enabled,
          sales_channel,
          starts_at,
          ends_at,
          archived_at
        ]
      )

    [[id]] = result.rows

    TicketOffer
    |> Query.for_read(:get_by_id, %{id: id}, actor: admin_actor([event_id]), authorize?: false)
    |> Ash.read_one!(authorize?: false)
  end

  defp admin_actor(event_ids) do
    %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: event_ids}
  end
end
