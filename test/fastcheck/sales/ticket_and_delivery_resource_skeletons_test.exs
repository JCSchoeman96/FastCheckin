defmodule FastCheck.Sales.TicketAndDeliveryResourceSkeletonsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type
  alias AshPostgres.DataLayer

  @resources [
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt
  ]

  @read_action_names [:read, :get_by_id]

  @shared_forbidden_action_names [
    :create,
    :update,
    :destroy,
    :upsert,
    :update_status,
    :update_state
  ]

  @ticket_issue_forbidden_action_names [
    :create_pending,
    :mark_issued,
    :mark_revoked,
    :mark_manual_review,
    :generate_ticket_code,
    :generate_qr_token,
    :generate_delivery_token,
    :issue_ticket,
    :revoke_ticket,
    :resend_ticket
  ]

  @delivery_attempt_forbidden_action_names [
    :create_queued,
    :mark_sent,
    :mark_delivered,
    :mark_failed,
    :mark_fallback_required,
    :send_whatsapp,
    :send_email,
    :send_template,
    :resend_ticket
  ]

  @ticket_issue_statuses ~w(pending issued revoked manual_review)

  @sensitive_attributes %{
    FastCheck.Sales.TicketIssue => [
      :ticket_code,
      :qr_token_hash,
      :delivery_token_hash,
      :attendee_id
    ],
    FastCheck.Sales.DeliveryAttempt => [
      :recipient,
      :provider_error_message,
      :failure_reason
    ]
  }

  test "all VS-01D resources compile and use AshPostgres" do
    for resource <- @resources do
      assert Code.ensure_loaded?(resource), "#{inspect(resource)} is missing"
      assert ResourceInfo.data_layer(resource) == DataLayer
    end
  end

  test "resources expose read-only actions only" do
    forbidden_by_resource = %{
      FastCheck.Sales.TicketIssue => @ticket_issue_forbidden_action_names,
      FastCheck.Sales.DeliveryAttempt => @delivery_attempt_forbidden_action_names
    }

    for resource <- @resources do
      actions = ResourceInfo.actions(resource)
      action_names = MapSet.new(actions, & &1.name)

      assert MapSet.subset?(MapSet.new(@read_action_names), action_names),
             "#{inspect(resource)} must expose basic read actions"

      refute Enum.any?(actions, &(&1.type in [:create, :update, :destroy])),
             "#{inspect(resource)} must not expose mutating Ash actions"

      for forbidden <-
            @shared_forbidden_action_names ++ Map.fetch!(forbidden_by_resource, resource) do
        refute forbidden in action_names,
               "#{inspect(resource)} must not expose #{inspect(forbidden)}"
      end
    end
  end

  test "ticket issues expose required attributes, relationships, and sensitive fields" do
    resource = FastCheck.Sales.TicketIssue

    assert_attributes(resource, [
      :id,
      :sales_order_id,
      :sales_order_line_id,
      :line_item_sequence,
      :attendee_id,
      :ticket_code,
      :qr_token_hash,
      :delivery_token_hash,
      :delivery_token_expires_at,
      :status,
      :scanner_status,
      :last_scanner_sync_version,
      :issued_at,
      :revoked_at,
      :revocation_reason,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(resource, :line_item_sequence, :integer)
    assert_attribute_type(resource, :last_scanner_sync_version, :integer)
    assert_relationship(resource, :order, :belongs_to, FastCheck.Sales.Order)
    assert_relationship(resource, :order_line, :belongs_to, FastCheck.Sales.OrderLine)

    assert_relationship(
      resource,
      :delivery_attempts,
      :has_many,
      FastCheck.Sales.DeliveryAttempt
    )

    refute ResourceInfo.relationship(resource, :attendee)
    assert_sensitive_attributes(resource)
    assert_ticket_issue_list_actions(resource)
  end

  test "delivery attempts expose required attributes, relationships, and sensitive fields" do
    resource = FastCheck.Sales.DeliveryAttempt

    assert_attributes(resource, [
      :id,
      :sales_order_id,
      :ticket_issue_id,
      :channel,
      :provider,
      :recipient,
      :status,
      :template_name,
      :within_whatsapp_window,
      :provider_message_id,
      :attempt_number,
      :provider_error_code,
      :provider_error_message,
      :failure_reason,
      :fallback_channel,
      :correlation_id,
      :sent_at,
      :delivered_at,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(resource, :attempt_number, :integer)
    assert_relationship(resource, :order, :belongs_to, FastCheck.Sales.Order)
    assert_relationship(resource, :ticket_issue, :belongs_to, FastCheck.Sales.TicketIssue)
    assert_sensitive_attributes(resource)
    assert_delivery_attempt_list_actions(resource)
  end

  test "orders and order lines expose ticket and delivery relationships" do
    assert_relationship(
      FastCheck.Sales.Order,
      :ticket_issues,
      :has_many,
      FastCheck.Sales.TicketIssue
    )

    assert_relationship(
      FastCheck.Sales.Order,
      :delivery_attempts,
      :has_many,
      FastCheck.Sales.DeliveryAttempt
    )

    assert_relationship(
      FastCheck.Sales.OrderLine,
      :ticket_issues,
      :has_many,
      FastCheck.Sales.TicketIssue
    )
  end

  test "ticket issue status represents issuance and validity only" do
    refute "delivered" in @ticket_issue_statuses
    refute "delivery_failed" in @ticket_issue_statuses
    refute "queued" in @ticket_issue_statuses
  end

  test "resources do not include deferred organization tenancy" do
    for resource <- @resources do
      refute ResourceInfo.attribute(resource, :organization_id),
             "#{inspect(resource)} must not define organization_id in VS-01D"
    end
  end

  test "resources do not define plaintext token attributes" do
    forbidden_names = [:delivery_token, :qr_token]

    for resource <- @resources do
      actual_names = Enum.map(ResourceInfo.attributes(resource), & &1.name)

      for forbidden <- forbidden_names do
        refute forbidden in actual_names,
               "#{inspect(resource)} must not define plaintext #{inspect(forbidden)}"
      end
    end
  end

  defp assert_ticket_issue_list_actions(resource) do
    assert ResourceInfo.action(resource, :list_by_order)
    assert ResourceInfo.action(resource, :list_by_order_line)
  end

  defp assert_delivery_attempt_list_actions(resource) do
    assert ResourceInfo.action(resource, :list_by_order)
    assert ResourceInfo.action(resource, :list_by_ticket_issue)
    assert ResourceInfo.action(resource, :list_by_status)
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

  defp assert_sensitive_attributes(resource) do
    for attribute_name <- Map.fetch!(@sensitive_attributes, resource) do
      assert %{sensitive?: true} = ResourceInfo.attribute(resource, attribute_name)
    end
  end
end
