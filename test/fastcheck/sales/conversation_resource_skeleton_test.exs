defmodule FastCheck.Sales.ConversationResourceSkeletonTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type
  alias AshPostgres.DataLayer

  @resource FastCheck.Sales.Conversation

  @read_action_names [
    :read,
    :get_by_id,
    :list_recent,
    :list_needing_human,
    :list_by_phone,
    :list_by_wa_id
  ]

  @checkpoint_action_names [
    :create_inbound_checkpoint,
    :update_inbound_checkpoint,
    :start_language_selection,
    :start_default_main_menu,
    :select_language,
    :choose_buy_tickets,
    :choose_resend_ticket,
    :select_event,
    :select_ticket_type,
    :submit_quantity,
    :submit_buyer_name,
    :submit_buyer_email,
    :submit_resend_name,
    :submit_resend_email,
    :verify_resend_otp,
    :skip_optional_email_after_name,
    :confirm_order,
    :return_to_event_selection,
    :return_to_ticket_type_selection,
    :return_to_quantity_collection,
    :return_to_buyer_name_collection,
    :return_to_email_collection,
    :return_to_resend_name_collection,
    :return_to_resend_email_collection,
    :return_to_main_menu,
    :cancel_conversation,
    :handoff_conversation,
    :mark_conversation_payment_pending,
    :request_payment_email
  ]

  @forbidden_action_names [
    :create,
    :update,
    :destroy,
    :upsert,
    :update_status,
    :update_state,
    :start_or_resume,
    :move_to_main_menu,
    :select_offer,
    :select_quantity,
    :collect_buyer_name,
    :collect_email,
    :mark_awaiting_payment,
    :mark_payment_pending,
    :mark_ticket_issued,
    :mark_needs_human,
    :expire_conversation
  ]

  @sensitive_attributes [
    :phone_e164,
    :wa_id,
    :session_key,
    :rate_limit_key,
    :state_data,
    :last_inbound_message_id,
    :last_outbound_message_id,
    :handoff_reason
  ]

  test "conversation compiles and uses AshPostgres" do
    assert Code.ensure_loaded?(@resource), "#{inspect(@resource)} is missing"
    assert ResourceInfo.data_layer(@resource) == DataLayer
  end

  test "conversation exposes read plus VS-17 checkpoint and VS-18 named actions" do
    actions = ResourceInfo.actions(@resource)
    action_names = MapSet.new(actions, & &1.name)

    assert MapSet.subset?(MapSet.new(@read_action_names), action_names),
           "Conversation must expose basic read/list actions"

    mutating_action_names =
      actions
      |> Enum.filter(&(&1.type in [:create, :update, :destroy]))
      |> MapSet.new(& &1.name)

    assert mutating_action_names == MapSet.new(@checkpoint_action_names),
           "Conversation may only expose VS-17 checkpoint and VS-18 named mutating actions"

    for forbidden <- @forbidden_action_names do
      refute forbidden in action_names,
             "Conversation must not expose #{inspect(forbidden)} in VS-01E"
    end
  end

  test "conversation exposes required attributes and sensitive fields" do
    assert_attributes(@resource, [
      :id,
      :phone_e164,
      :wa_id,
      :session_key,
      :rate_limit_key,
      :preferred_language,
      :locale,
      :state,
      :state_data,
      :last_inbound_message_id,
      :last_outbound_message_id,
      :last_message_at,
      :expires_at,
      :needs_human,
      :handoff_reason,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(@resource, :state_data, :map)
    assert_attribute_type(@resource, :needs_human, :boolean)
    assert_sensitive_attributes(@resource)

    refute ResourceInfo.attribute(@resource, :organization_id),
           "Conversation must not define organization_id in VS-01E"
  end

  test "conversation and order expose optional relationships" do
    assert_relationship(@resource, :orders, :has_many, FastCheck.Sales.Order)
    assert_relationship(FastCheck.Sales.Order, :conversation, :belongs_to, @resource)
  end

  test "conversation does not define plaintext token or raw payload attributes" do
    actual_names =
      @resource
      |> ResourceInfo.attributes()
      |> MapSet.new(& &1.name)

    for forbidden <- [:delivery_token, :qr_token, :access_token, :raw_payload, :message_body] do
      refute forbidden in actual_names,
             "Conversation must not define #{inspect(forbidden)} in VS-01E"
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
        :boolean -> Type.Boolean
        :map -> Type.Map
      end

    assert %{type: ^ash_type} = ResourceInfo.attribute(resource, attribute_name)
  end

  defp assert_relationship(resource, name, type, destination) do
    assert relationship = ResourceInfo.relationship(resource, name)
    assert relationship.type == type
    assert relationship.destination == destination
  end

  defp assert_sensitive_attributes(resource) do
    for attribute_name <- @sensitive_attributes do
      assert %{sensitive?: true} = ResourceInfo.attribute(resource, attribute_name)
    end
  end
end
