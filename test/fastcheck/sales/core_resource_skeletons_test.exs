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
    :record_transition,
    :create_offer,
    :update_offer,
    :enable_sales,
    :disable_sales,
    :create_draft,
    :confirm_checkout,
    :mark_awaiting_payment,
    :mark_payment_pending,
    :mark_paid_verified,
    :queue_fulfillment,
    :mark_ticket_issued,
    :create_for_order
  ]

  test "all VS-01B resources compile and use AshPostgres" do
    for resource <- @resources do
      assert Code.ensure_loaded?(resource), "#{inspect(resource)} is missing"
      assert ResourceInfo.data_layer(resource) == DataLayer
    end
  end

  test "resources expose read-only actions only" do
    for resource <- @resources do
      actions = ResourceInfo.actions(resource)
      action_names = MapSet.new(actions, & &1.name)

      assert MapSet.subset?(MapSet.new(@read_action_names), action_names),
             "#{inspect(resource)} must expose basic read actions"

      refute Enum.any?(actions, &(&1.type in [:create, :update, :destroy])),
             "#{inspect(resource)} must not expose mutating Ash actions"

      for forbidden <- @forbidden_action_names do
        refute forbidden in action_names,
               "#{inspect(resource)} must not expose #{inspect(forbidden)}"
      end
    end
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

    assert_relationship(
      FastCheck.Sales.TicketOffer,
      :order_lines,
      :has_many,
      FastCheck.Sales.OrderLine
    )
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

    assert_relationship(
      FastCheck.Sales.Order,
      :order_lines,
      :has_many,
      FastCheck.Sales.OrderLine
    )
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

    assert_attribute_type(FastCheck.Sales.OrderLine, :quantity, :integer)
    assert_attribute_type(FastCheck.Sales.OrderLine, :unit_amount_cents, :integer)
    assert_attribute_type(FastCheck.Sales.OrderLine, :total_amount_cents, :integer)
    assert_attribute_type(FastCheck.Sales.OrderLine, :metadata, :map)

    assert_relationship(FastCheck.Sales.OrderLine, :order, :belongs_to, FastCheck.Sales.Order)

    assert_relationship(
      FastCheck.Sales.OrderLine,
      :ticket_offer,
      :belongs_to,
      FastCheck.Sales.TicketOffer
    )
  end

  test "state transitions expose required attributes and no relationships" do
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

    assert_attribute_type(FastCheck.Sales.StateTransition, :metadata, :map)
    assert ResourceInfo.relationships(FastCheck.Sales.StateTransition) == []
  end

  test "resources do not include deferred organization tenancy" do
    for resource <- @resources do
      refute ResourceInfo.attribute(resource, :organization_id),
             "#{inspect(resource)} must not define organization_id in VS-01B"
    end
  end

  defp assert_attributes(resource, expected_attributes) do
    actual_attributes =
      resource
      |> ResourceInfo.attributes()
      |> MapSet.new(& &1.name)

    for attribute <- expected_attributes do
      assert attribute in actual_attributes,
             "#{inspect(resource)} is missing attribute #{inspect(attribute)}"
    end
  end

  defp assert_attribute_type(resource, attribute_name, expected_type) do
    ash_type =
      case expected_type do
        :integer -> Type.Integer
        :map -> Type.Map
      end

    assert %{type: ^ash_type} = ResourceInfo.attribute(resource, attribute_name)
  end

  defp assert_relationship(resource, name, type, destination) do
    assert relationship = ResourceInfo.relationship(resource, name)
    assert relationship.type == type
    assert relationship.destination == destination
  end
end
