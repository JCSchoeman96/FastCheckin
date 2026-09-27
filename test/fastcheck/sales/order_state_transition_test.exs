defmodule FastCheck.Sales.OrderStateTransitionTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.StateTransition

  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    Fixtures.ensure_event_for_sales!(Fixtures.event_id())
    :ok
  end

  test "state transitions are appended for order status changes" do
    actor = Fixtures.system_actor()

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-st-#{System.unique_integer([:positive])}",
          event_id: Fixtures.event_id(),
          source_channel: "test",
          total_amount_cents: 1000,
          currency: "ZAR",
          idempotency_key: "st-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    order =
      order
      |> Changeset.for_update(:mark_awaiting_payment, %{}, actor: actor)
      |> Ash.update!(authorize?: false)

    assert order.status == "awaiting_payment"

    transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{entity_type: "Order", entity_id: to_string(order.id)})
      |> Ash.read!(authorize?: false)

    assert Enum.any?(transitions, &(&1.from_state == nil and &1.to_state == "draft"))

    assert Enum.any?(
             transitions,
             &(&1.from_state == "draft" and &1.to_state == "awaiting_payment")
           )
  end

  test "manual admin transition requires reason" do
    actor = Fixtures.admin_actor()

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-manual-#{System.unique_integer([:positive])}",
          event_id: Fixtures.event_id(),
          source_channel: "admin",
          total_amount_cents: 1000,
          currency: "ZAR"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    assert {:error, _} =
             order
             |> Changeset.for_update(:cancel_order, %{}, actor: actor)
             |> Ash.update(authorize?: true)
  end

  test "queue_fulfillment records one timestamped transition and is idempotent" do
    order = paid_verified_order!()
    actor = Fixtures.system_actor()

    assert {:ok, queued} =
             order
             |> Changeset.for_update(:queue_fulfillment, %{}, actor: actor)
             |> Ash.update(authorize?: true)

    assert queued.status == "fulfillment_queued"
    assert %DateTime{} = queued.fulfillment_queued_at

    assert {:ok, retried} =
             queued
             |> Changeset.for_update(:queue_fulfillment, %{}, actor: actor)
             |> Ash.update(authorize?: true)

    assert retried.status == "fulfillment_queued"
    assert retried.fulfillment_queued_at == queued.fulfillment_queued_at
    assert transition_count(order.id, "fulfillment_queued") == 1
  end

  test "queue_fulfillment rejects a non-system actor" do
    order = paid_verified_order!()

    assert {:error, _} =
             order
             |> Changeset.for_update(:queue_fulfillment, %{}, actor: Fixtures.admin_actor())
             |> Ash.update(authorize?: true)

    assert reload_order!(order.id).status == "paid_verified"
  end

  test "queue_fulfillment rejects an existing queued state without its boundary timestamp" do
    order = paid_verified_order!()
    actor = Fixtures.system_actor()

    assert {:ok, _queued} =
             order
             |> Changeset.for_update(:queue_fulfillment, %{}, actor: actor)
             |> Ash.update(authorize?: true)

    Repo.query!(
      "UPDATE sales_orders SET fulfillment_queued_at = NULL WHERE id = $1",
      [order.id]
    )

    queued = reload_order!(order.id)

    assert {:error, _} =
             queued
             |> Changeset.for_update(:queue_fulfillment, %{}, actor: actor)
             |> Ash.update(authorize?: true)

    assert transition_count(order.id, "fulfillment_queued") == 1
  end

  test "mark_ticket_issued cannot bypass fulfillment from paid_verified" do
    order = paid_verified_order!()

    assert {:error, _} =
             order
             |> Changeset.for_update(:mark_ticket_issued, %{}, actor: Fixtures.system_actor())
             |> Ash.update(authorize?: true)

    assert reload_order!(order.id).status == "paid_verified"
    assert transition_count(order.id, "ticket_issued") == 0
  end

  defp paid_verified_order! do
    actor = Fixtures.system_actor()

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-fulfillment-#{System.unique_integer([:positive])}",
          event_id: Fixtures.event_id(),
          source_channel: "test",
          total_amount_cents: 1000,
          currency: "ZAR",
          idempotency_key: "fulfillment-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    order
    |> Changeset.for_update(:mark_awaiting_payment, %{}, actor: actor)
    |> Ash.update!(authorize?: false)
    |> Changeset.for_update(:mark_paid_verified, %{}, actor: actor)
    |> Ash.update!(authorize?: false)
  end

  defp reload_order!(id) do
    Order
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one!(authorize?: false)
  end

  defp transition_count(order_id, state) do
    transitions =
      StateTransition
      |> Query.for_read(:list_for_entity, %{
        entity_type: "Order",
        entity_id: to_string(order_id)
      })
      |> Ash.read!(authorize?: false)

    Enum.count(transitions, &(&1.to_state == state))
  end
end
