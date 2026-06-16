defmodule FastCheck.Sales.TicketOfferPolicyTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.TicketOffer

  @event_id 44_001
  @other_event_id 44_002

  setup do
    offer_id = insert_offer!(@event_id)
    {:ok, offer_id: offer_id}
  end

  test "operator can read scoped active offers only", %{offer_id: offer_id} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    results =
      TicketOffer
      |> Query.for_read(
        :list_active_for_event,
        %{event_id: @event_id, sales_channel: "whatsapp", as_of: now},
        actor: operator_actor([@event_id]),
        authorize?: true
      )
      |> Ash.read!(authorize?: true)

    assert Enum.map(results, & &1.id) == [offer_id]
  end

  test "customer_session can use controlled actions but not broad read", %{offer_id: offer_id} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert_raise Ash.Error.Forbidden, fn ->
      TicketOffer
      |> Query.for_read(:read, %{}, actor: customer_actor([@event_id]), authorize?: true)
      |> Ash.read!(authorize?: true, authorize_with: :error)
    end

    result =
      TicketOffer
      |> Query.for_read(
        :get_available_for_checkout,
        %{id: offer_id, event_id: @event_id, sales_channel: "whatsapp", as_of: now},
        actor: customer_actor([@event_id]),
        authorize?: true
      )
      |> Ash.read_one!(authorize?: true)

    assert result.id == offer_id
  end

  test "customer_session cannot access another event offer", %{offer_id: offer_id} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      TicketOffer
      |> Query.for_read(
        :get_available_for_checkout,
        %{id: offer_id, event_id: @event_id, sales_channel: "whatsapp", as_of: now},
        actor: customer_actor([@other_event_id]),
        authorize?: true
      )
      |> Ash.read_one!(authorize?: true)

    assert result == nil
  end

  test "operator cannot mutate and admin can mutate", %{offer_id: offer_id} do
    offer =
      TicketOffer
      |> Query.for_read(:get_by_id, %{id: offer_id},
        actor: admin_actor([@event_id]),
        authorize?: true
      )
      |> Ash.read_one!(authorize?: true)

    assert_raise Ash.Error.Forbidden, fn ->
      offer
      |> Changeset.for_update(:disable_sales, %{},
        actor: operator_actor([@event_id]),
        authorize?: true
      )
      |> Ash.update!(authorize?: true)
    end

    updated =
      offer
      |> Changeset.for_update(:disable_sales, %{},
        actor: admin_actor([@event_id]),
        authorize?: true
      )
      |> Ash.update!(authorize?: true)

    refute updated.sales_enabled
  end

  defp insert_offer!(event_id) do
    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', 10000, 'ZAR', 100, 100, 2, true, 'whatsapp', NULL, NULL, 1, now(), now())
        RETURNING id
        """,
        [event_id, "Offer-#{System.unique_integer([:positive])}"]
      )

    [[id]] = result.rows
    id
  end

  defp admin_actor(event_ids),
    do: %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: event_ids}

  defp operator_actor(event_ids),
    do: %{actor_type: :operator, user_id: "operator-1", allowed_event_ids: event_ids}

  defp customer_actor(event_ids),
    do: %{actor_type: :customer_session, actor_id: "customer-1", allowed_event_ids: event_ids}
end
