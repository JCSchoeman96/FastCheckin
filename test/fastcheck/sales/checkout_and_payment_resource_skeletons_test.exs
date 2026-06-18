defmodule FastCheck.Sales.CheckoutAndPaymentResourceSkeletonsTest do
  use ExUnit.Case, async: true

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type
  alias AshPostgres.DataLayer

  @resources [
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent
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

  @checkout_expected_action_names [
    :create_session,
    :attach_inventory_hold,
    :mark_payment_link_sent,
    :expire_session,
    :release_session,
    :mark_manual_review
  ]

  @payment_attempt_expected_action_names [
    :get_active_by_idempotency_key,
    :create_initializing,
    :mark_initialized,
    :mark_failed,
    :mark_manual_review
  ]

  @payment_attempt_forbidden_action_names [
    :create_initialized,
    :mark_authorization_url_sent,
    :mark_webhook_received,
    :mark_verification_started,
    :mark_verified_success,
    :mark_amount_mismatch,
    :mark_currency_mismatch,
    :mark_duplicate
  ]

  @payment_event_expected_action_names [
    :store_webhook_event,
    :get_by_provider_event_id,
    :get_by_provider_payload_hash
  ]

  @payment_event_forbidden_action_names [
    :mark_processing_started,
    :mark_processed,
    :mark_duplicate,
    :mark_unmatched,
    :mark_failed
  ]

  @sensitive_attributes %{
    FastCheck.Sales.CheckoutSession => [:hold_token],
    FastCheck.Sales.PaymentAttempt => [
      :authorization_url,
      :access_code,
      :raw_initialize_response,
      :raw_verify_response
    ],
    FastCheck.Sales.PaymentEvent => [:raw_payload]
  }

  test "all VS-01C resources compile and use AshPostgres" do
    for resource <- @resources do
      assert Code.ensure_loaded?(resource), "#{inspect(resource)} is missing"
      assert ResourceInfo.data_layer(resource) == DataLayer
    end
  end

  test "resources expose expected action surfaces" do
    forbidden_by_resource = %{
      FastCheck.Sales.CheckoutSession => [],
      FastCheck.Sales.PaymentAttempt => @payment_attempt_forbidden_action_names,
      FastCheck.Sales.PaymentEvent => @payment_event_forbidden_action_names
    }

    for resource <- @resources do
      actions = ResourceInfo.actions(resource)
      action_names = MapSet.new(actions, & &1.name)

      assert MapSet.subset?(MapSet.new(@read_action_names), action_names),
             "#{inspect(resource)} must expose basic read actions"

      cond do
        resource == FastCheck.Sales.CheckoutSession ->
          for expected <- @checkout_expected_action_names do
            assert expected in action_names,
                   "#{inspect(resource)} must expose #{inspect(expected)}"
          end

        resource == FastCheck.Sales.PaymentAttempt ->
          for expected <- @payment_attempt_expected_action_names do
            assert expected in action_names,
                   "#{inspect(resource)} must expose #{inspect(expected)}"
          end

        resource == FastCheck.Sales.PaymentEvent ->
          for expected <- @payment_event_expected_action_names do
            assert expected in action_names,
                   "#{inspect(resource)} must expose #{inspect(expected)}"
          end

        true ->
          refute Enum.any?(actions, &(&1.type in [:create, :update, :destroy])),
                 "#{inspect(resource)} must not expose mutating Ash actions"
      end

      for forbidden <-
            @shared_forbidden_action_names ++ Map.fetch!(forbidden_by_resource, resource) do
        refute forbidden in action_names,
               "#{inspect(resource)} must not expose #{inspect(forbidden)}"
      end
    end
  end

  test "checkout sessions expose required attributes, relationships, and sensitive fields" do
    resource = FastCheck.Sales.CheckoutSession

    assert_attributes(resource, [
      :id,
      :sales_order_id,
      :status,
      :redis_hold_key,
      :hold_token,
      :hold_quantity,
      :payment_link_sent_at,
      :released_at,
      :expired_at,
      :last_seen_at,
      :expires_at,
      :state_data,
      :lock_version,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(resource, :hold_quantity, :integer)
    assert_attribute_type(resource, :state_data, :map)
    assert_attribute_type(resource, :lock_version, :integer)
    assert_relationship(resource, :order, :belongs_to, FastCheck.Sales.Order)
    assert_sensitive_attributes(resource)
  end

  test "payment attempts expose required attributes, relationships, and sensitive fields" do
    resource = FastCheck.Sales.PaymentAttempt

    assert_attributes(resource, [
      :id,
      :sales_order_id,
      :provider,
      :provider_reference,
      :idempotency_key,
      :authorization_url,
      :access_code,
      :status,
      :provider_status,
      :amount_cents,
      :currency,
      :initialized_at,
      :provider_paid_at,
      :verified_at,
      :last_verified_at,
      :verification_attempt_count,
      :failure_code,
      :failure_message,
      :manual_review_reason,
      :raw_initialize_response,
      :raw_verify_response,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(resource, :amount_cents, :integer)
    assert_attribute_type(resource, :verification_attempt_count, :integer)
    assert_attribute_type(resource, :raw_initialize_response, :map)
    assert_attribute_type(resource, :raw_verify_response, :map)
    assert_relationship(resource, :order, :belongs_to, FastCheck.Sales.Order)
    assert_sensitive_attributes(resource)
  end

  test "payment events expose required attributes and no payment attempt relationship" do
    resource = FastCheck.Sales.PaymentEvent

    assert_attributes(resource, [
      :id,
      :provider,
      :provider_event_id,
      :provider_reference,
      :event_type,
      :signature_valid,
      :payload_hash,
      :raw_payload,
      :received_at,
      :processed_at,
      :processing_status,
      :processing_attempt_count,
      :last_processing_error,
      :last_processing_error_at,
      :inserted_at,
      :updated_at
    ])

    assert_attribute_type(resource, :raw_payload, :map)
    assert_attribute_type(resource, :processing_attempt_count, :integer)
    refute ResourceInfo.relationship(resource, :payment_attempt)
    assert_sensitive_attributes(resource)
  end

  test "orders expose checkout and payment attempt relationships" do
    assert_relationship(
      FastCheck.Sales.Order,
      :checkout_session,
      :has_one,
      FastCheck.Sales.CheckoutSession
    )

    assert_relationship(
      FastCheck.Sales.Order,
      :payment_attempts,
      :has_many,
      FastCheck.Sales.PaymentAttempt
    )
  end

  test "resources do not include deferred organization tenancy" do
    for resource <- @resources do
      refute ResourceInfo.attribute(resource, :organization_id),
             "#{inspect(resource)} must not define organization_id in VS-01C"
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

  defp assert_sensitive_attributes(resource) do
    for attribute_name <- Map.fetch!(@sensitive_attributes, resource) do
      assert %{sensitive?: true} = ResourceInfo.attribute(resource, attribute_name)
    end
  end
end
