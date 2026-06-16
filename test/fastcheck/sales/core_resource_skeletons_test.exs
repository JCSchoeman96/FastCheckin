defmodule FastCheck.Sales.CoreResourceSkeletonsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type
  alias AshPostgres.DataLayer

  @resources [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.StateTransition
  ]

  @read_action_names [:read, :get_by_id]

  @forbidden_action_names [
    :create,
    :update,
    :destroy,
    :upsert,
    :update_status,
    :update_state,
    :mark_paid_verified,
    :queue_fulfillment,
    :mark_ticket_issued
  ]

  @order_expected_actions [
    :create_draft,
    :confirm_checkout,
    :mark_awaiting_payment,
    :mark_payment_pending,
    :mark_paid_unverified,
    :expire_order,
    :cancel_order,
    :mark_manual_review,
    :get_by_public_reference,
    :get_by_idempotency_key
  ]

  @order_line_expected_actions [:create_for_order, :list_for_order]
  @state_transition_expected_actions [:record_transition, :list_for_entity]

  test "all VS-01B resources compile and use AshPostgres" do
    for resource <- @resources do
      assert Code.ensure_loaded?(resource), "#{inspect(resource)} is missing"
      assert ResourceInfo.data_layer(resource) == DataLayer
    end
  end

  test "resources expose expected VS-05 action surfaces" do
    assert_actions(FastCheck.Sales.Order, @order_expected_actions)
    assert_actions(FastCheck.Sales.OrderLine, @order_line_expected_actions)
    assert_actions(FastCheck.Sales.StateTransition, @state_transition_expected_actions)

    for resource <- @resources, forbidden <- @forbidden_action_names do
      action_names = ResourceInfo.actions(resource) |> Enum.map(& &1.name)

      refute forbidden in action_names,
             "#{inspect(resource)} must not expose #{inspect(forbidden)}"
    end
  end

  test "TicketOffer exposes VS-03 named management actions" do
    actions = ResourceInfo.actions(FastCheck.Sales.TicketOffer)
    action_names = MapSet.new(actions, & &1.name)

    assert :create_offer in action_names
    assert :update_offer in action_names
    assert :enable_sales in action_names
    assert :disable_sales in action_names
    assert :list_active_for_event in action_names
    assert :get_available_for_checkout in action_names
  end

  test "ticket offers expose required attributes and relationships" do
    assert_attributes(FastCheck.Sales.TicketOffer, [
      :id,
      :event_id,
      :name,
      :ticket_type,
      :price_cents,
      :currency,
      :configured_quantity_available,
      :initial_quantity,
      :max_per_order,
      :sales_enabled,
      :sales_channel,
      :starts_at,
      :ends_at,
      :lock_version,
      :archived_at,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(FastCheck.Sales.TicketOffer, :price_cents, :integer)
    assert_attribute_type(FastCheck.Sales.TicketOffer, :configured_quantity_available, :integer)
    assert_attribute_type(FastCheck.Sales.TicketOffer, :initial_quantity, :integer)

    assert_relationship(FastCheck.Sales.TicketOffer, :order_lines, :has_many)
  end

  test "orders expose required attributes and relationships" do
    assert_attributes(FastCheck.Sales.Order, [
      :id,
      :public_reference,
      :event_id,
      :buyer_name,
      :buyer_phone,
      :buyer_email,
      :source_channel,
      :status,
      :total_amount_cents,
      :currency,
      :whatsapp_conversation_id,
      :sales_conversation_id,
      :idempotency_key,
      :expires_at,
      :paid_at,
      :fulfillment_queued_at,
      :ticket_issued_at,
      :cancelled_at,
      :expired_at,
      :refunded_at,
      :manual_review_reason,
      :last_error_code,
      :last_error_message,
      :lock_version,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(FastCheck.Sales.Order, :total_amount_cents, :integer)
    assert_relationship(FastCheck.Sales.Order, :order_lines, :has_many)
    assert_relationship(FastCheck.Sales.Order, :checkout_session, :has_one)
  end

  test "order lines expose required attributes and relationships" do
    assert_attributes(FastCheck.Sales.OrderLine, [
      :id,
      :sales_order_id,
      :ticket_offer_id,
      :line_number,
      :ticket_type,
      :offer_name_snapshot,
      :event_name_snapshot,
      :quantity,
      :unit_amount_cents,
      :total_amount_cents,
      :currency,
      :metadata,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(FastCheck.Sales.OrderLine, :unit_amount_cents, :integer)
    assert_attribute_type(FastCheck.Sales.OrderLine, :total_amount_cents, :integer)
    assert_relationship(FastCheck.Sales.OrderLine, :order, :belongs_to)
    assert_relationship(FastCheck.Sales.OrderLine, :ticket_offer, :belongs_to)
  end

  test "state transitions expose required attributes" do
    assert_attributes(FastCheck.Sales.StateTransition, [
      :id,
      :entity_type,
      :entity_id,
      :from_state,
      :to_state,
      :reason,
      :actor_type,
      :actor_id,
      :metadata,
      :correlation_id,
      :request_id,
      :idempotency_key,
      :source,
      :inserted_at
    ])
  end

  test "resources do not expose organization_id" do
    for resource <- @resources do
      refute Enum.any?(ResourceInfo.attributes(resource), &(&1.name == :organization_id))
    end
  end

  defp assert_actions(resource, expected_subset) do
    action_names = ResourceInfo.actions(resource) |> Enum.map(& &1.name) |> MapSet.new()

    assert MapSet.subset?(MapSet.new(@read_action_names), action_names),
           "#{inspect(resource)} must expose basic read actions"

    for expected <- expected_subset do
      assert expected in action_names,
             "#{inspect(resource)} must expose #{inspect(expected)}"
    end
  end

  defp assert_attributes(resource, expected_names) do
    names = ResourceInfo.attributes(resource) |> Enum.map(& &1.name)
    assert Enum.sort(names) == Enum.sort(expected_names)
  end

  defp assert_attribute_type(resource, name, expected_type) do
    ash_type =
      case expected_type do
        :integer -> Type.Integer
        :string -> Type.String
        :boolean -> Type.Boolean
        :map -> Type.Map
        :utc_datetime -> Type.UtcDatetime
      end

    assert %{type: ^ash_type} = ResourceInfo.attribute(resource, name)
  end

  defp assert_relationship(resource, name, type) do
    relationship = Enum.find(ResourceInfo.relationships(resource), &(&1.name == name))
    assert relationship.type == type
  end
end
