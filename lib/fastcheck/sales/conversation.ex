defmodule FastCheck.Sales.Conversation do
  @moduledoc """
  Durable WhatsApp conversation checkpoint skeleton.

  VS-01E stores recoverable conversation checkpoint shape only. Meta webhooks,
  WhatsApp sending, Redis session/rate-limit behavior, checkout creation,
  payment handling, ticket delivery, and menu workflow actions are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Sales.StateTransitionSupport

  @vs_18_checkpoint_fields [
    :preferred_language,
    :state_data,
    :last_inbound_message_id,
    :last_outbound_message_id,
    :last_message_at,
    :expires_at,
    :needs_human,
    :handoff_reason
  ]

  postgres do
    table("sales_conversations")
    repo(FastCheck.Repo)
  end

  actions do
    defaults([:read])

    read :get_by_id do
      get?(true)

      argument :id, :integer do
        allow_nil?(false)
      end

      filter(expr(id == ^arg(:id)))
    end

    read(:list_recent)

    read :list_needing_human do
      filter(expr(needs_human == true))
    end

    read :list_by_phone do
      argument :phone_e164, :string do
        allow_nil?(false)
      end

      filter(expr(phone_e164 == ^arg(:phone_e164)))
    end

    read :list_by_wa_id do
      argument :wa_id, :string do
        allow_nil?(false)
      end

      filter(expr(wa_id == ^arg(:wa_id)))
    end

    create :create_inbound_checkpoint do
      accept([
        :phone_e164,
        :wa_id,
        :session_key,
        :rate_limit_key,
        :preferred_language,
        :state,
        :state_data,
        :last_inbound_message_id,
        :last_message_at,
        :expires_at,
        :needs_human,
        :handoff_reason
      ])
    end

    update :update_inbound_checkpoint do
      require_atomic?(false)

      accept([
        :phone_e164,
        :wa_id,
        :session_key,
        :rate_limit_key,
        :preferred_language,
        :state_data,
        :last_inbound_message_id,
        :last_message_at,
        :expires_at,
        :needs_human,
        :handoff_reason
      ])
    end

    update :start_language_selection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "selecting_language", :start_language_selection))
    end

    update :start_default_main_menu do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "main_menu", :start_default_main_menu))
    end

    update :select_language do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "main_menu", :select_language))
    end

    update :choose_buy_tickets do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "selecting_event", :choose_buy_tickets))
    end

    update :choose_resend_ticket do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_resend_name", :choose_resend_ticket))
    end

    update :select_event do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "selecting_ticket_type", :select_event))
    end

    update :select_ticket_type do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_quantity", :select_ticket_type))
    end

    update :submit_quantity do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_buyer_name", :submit_quantity))
    end

    update :submit_buyer_name do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_email", :submit_buyer_name))
    end

    update :submit_buyer_email do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "confirming_order", :submit_buyer_email))
    end

    update :submit_resend_name do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_resend_email", :submit_resend_name))
    end

    update :submit_resend_email do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_resend_otp", :submit_resend_email))
    end

    update :skip_optional_email_after_name do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "confirming_order", :skip_optional_email_after_name))
    end

    update :confirm_order do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "awaiting_payment", :confirm_order))
    end

    update :return_to_event_selection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "selecting_event", :return_to_event_selection))
    end

    update :return_to_ticket_type_selection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "selecting_ticket_type", :return_to_ticket_type_selection))
    end

    update :return_to_quantity_collection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_quantity", :return_to_quantity_collection))
    end

    update :return_to_buyer_name_collection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_buyer_name", :return_to_buyer_name_collection))
    end

    update :return_to_email_collection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_email", :return_to_email_collection))
    end

    update :return_to_resend_name_collection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)

      change(
        &transition_state(&1, &2, "collecting_resend_name", :return_to_resend_name_collection)
      )
    end

    update :return_to_resend_email_collection do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)

      change(
        &transition_state(&1, &2, "collecting_resend_email", :return_to_resend_email_collection)
      )
    end

    update :verify_resend_otp do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)

      change(&transition_state(&1, &2, "awaiting_verified_resend_delivery", :verify_resend_otp))
    end

    update :return_to_main_menu do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "main_menu", :return_to_main_menu))
    end

    update :cancel_conversation do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:reason, :string)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "cancelled", :cancel_conversation))
    end

    update :handoff_conversation do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:reason, :string)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "manual_review", :handoff_conversation))
    end

    update :mark_conversation_payment_pending do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "payment_pending", :mark_conversation_payment_pending))
    end

    update :request_payment_email do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)
      change(&transition_state(&1, &2, "collecting_email", :request_payment_email))
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end
  end

  field_policies do
    private_fields(:include)

    field_policy :* do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :phone_e164, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :wa_id, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute(:session_key, :string, sensitive?: true)
    attribute(:rate_limit_key, :string, sensitive?: true)

    attribute :preferred_language, :string do
      allow_nil?(false)
      default("af")
    end

    attribute(:locale, :string)

    attribute :state, :string do
      allow_nil?(false)
      default("new")
    end

    attribute :state_data, :map do
      allow_nil?(false)
      default(%{})
      sensitive?(true)
    end

    attribute(:last_inbound_message_id, :string, sensitive?: true)
    attribute(:last_outbound_message_id, :string, sensitive?: true)
    attribute(:last_message_at, :utc_datetime)
    attribute(:expires_at, :utc_datetime)

    attribute :needs_human, :boolean do
      allow_nil?(false)
      default(false)
    end

    attribute(:handoff_reason, :string, sensitive?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :orders, FastCheck.Sales.Order do
      destination_attribute(:sales_conversation_id)
    end
  end

  defp transition_state(changeset, context, to_state, action_name) do
    from_state = Changeset.get_data(changeset, :state)

    reason =
      Changeset.get_argument(changeset, :reason) ||
        Changeset.get_attribute(changeset, :handoff_reason)

    action_context = action_context(changeset, context)

    transition_metadata =
      Changeset.get_argument(changeset, :transition_metadata) ||
        Map.get(action_context, :transition_metadata, %{})

    correlation_id =
      Changeset.get_argument(changeset, :correlation_id) ||
        Map.get(action_context, :correlation_id)

    idempotency_key =
      Changeset.get_argument(changeset, :idempotency_key) ||
        Map.get(action_context, :idempotency_key)

    changeset
    |> Changeset.force_change_attribute(:state, to_state)
    |> Changeset.after_action(fn _changeset, record ->
      case StateTransitionSupport.record!(
             %{
               entity_type: "conversation",
               entity_id: Integer.to_string(record.id),
               from_state: from_state,
               to_state: record.state,
               reason: reason,
               metadata: transition_metadata,
               correlation_id: correlation_id,
               idempotency_key: idempotency_key,
               source: "whatsapp.conversation.#{action_name}"
             },
             action_context
           ) do
        {:ok, _transition} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp action_context(changeset, context) do
    changeset_context = Map.get(changeset, :context) || %{}
    nested_context = Map.get(context, :context) || %{}

    context
    |> Map.merge(nested_context)
    |> Map.merge(changeset_context)
  end
end
