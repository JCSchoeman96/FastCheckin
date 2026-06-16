defmodule FastCheck.Sales.OrderStateTransitionTest do
  use FastCheck.DataCase, async: true

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.StateTransition

  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

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
end
