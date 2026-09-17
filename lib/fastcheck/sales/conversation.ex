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
  @pending_reply_statuses ["reply_pending", "reply_retryable"]
  @terminal_reply_statuses ["reply_sent", "reply_failed"]
  @reply_failure_classes [
    "whatsapp_reply_transport_failure",
    "whatsapp_reply_retry_exhausted",
    "whatsapp_reply_auth_failure",
    "whatsapp_reply_validation_failure",
    "whatsapp_reply_ciphertext_invalid",
    "whatsapp_reply_failed"
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

    update :store_pending_reply do
      require_atomic?(false)
      accept([])
      argument(:ciphertext, :string, allow_nil?: false)
      argument(:provider_message_id, :string, allow_nil?: false)
      argument(:computed_at, :utc_datetime, allow_nil?: false)
      argument(:correlation_id, :string)
      change(&store_pending_reply_change/2)
    end

    update :mark_reply_retryable do
      require_atomic?(false)
      accept([])
      argument(:provider_message_id, :string, allow_nil?: false)
      argument(:attempted_at, :utc_datetime, allow_nil?: false)
      argument(:failure_class, :string, allow_nil?: false)
      change(&mark_reply_retryable_change/2)
    end

    update :mark_reply_sent do
      require_atomic?(false)
      accept([])
      argument(:provider_message_id, :string, allow_nil?: false)
      argument(:outbound_message_id, :string, allow_nil?: false)
      argument(:sent_at, :utc_datetime, allow_nil?: false)
      change(&mark_reply_sent_change/2)
    end

    update :mark_reply_failed do
      require_atomic?(false)
      accept([])
      argument(:provider_message_id, :string, allow_nil?: false)
      argument(:failed_at, :utc_datetime, allow_nil?: false)
      argument(:failure_class, :string, allow_nil?: false)
      change(&mark_reply_failed_change/2)
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

    update :queue_verified_resend_delivery do
      require_atomic?(false)
      accept(@vs_18_checkpoint_fields)
      argument(:correlation_id, :string)
      argument(:idempotency_key, :string)
      argument(:transition_metadata, :map)

      change(
        &transition_state(
          &1,
          &2,
          "verified_resend_delivery_queued",
          :queue_verified_resend_delivery
        )
      )
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

  defp store_pending_reply_change(changeset, _context) do
    provider_message_id = Changeset.get_argument(changeset, :provider_message_id)
    state_data = current_state_data(changeset)
    existing_reply = Map.get(state_data, "pending_reply")

    cond do
      not valid_provider_message_id?(provider_message_id) ->
        reply_state_error(changeset, "reply provider is invalid")

      is_map(existing_reply) and
        Map.get(existing_reply, "provider_message_id") != provider_message_id and
          Map.get(existing_reply, "status") in @pending_reply_statuses ->
        changeset

      is_map(existing_reply) and
          Map.get(existing_reply, "provider_message_id") == provider_message_id ->
        changeset
        |> Changeset.force_change_attribute(
          :state_data,
          Map.put(state_data, "last_handled_inbound_message_id", provider_message_id)
        )

      is_map(existing_reply) and
          Map.get(existing_reply, "status") not in @terminal_reply_statuses ->
        reply_state_error(changeset, "reply delivery state is invalid")

      true ->
        pending_reply = %{
          "ciphertext" => Changeset.get_argument(changeset, :ciphertext),
          "provider_message_id" => provider_message_id,
          "status" => "reply_pending",
          "attempt_count" => 0,
          "computed_at" => iso8601(Changeset.get_argument(changeset, :computed_at)),
          "last_attempt_at" => nil,
          "failure_class" => nil
        }

        state_data =
          state_data
          |> Map.put("pending_reply", pending_reply)
          |> Map.put("last_handled_inbound_message_id", provider_message_id)

        Changeset.force_change_attribute(changeset, :state_data, state_data)
    end
  end

  defp mark_reply_retryable_change(changeset, _context) do
    provider_message_id = Changeset.get_argument(changeset, :provider_message_id)

    with {:ok, pending_reply} <-
           pending_reply_for_update(changeset, provider_message_id, @pending_reply_statuses),
         {:ok, attempt_count} <- reply_attempt_count(pending_reply),
         :ok <- validate_failure_class(Changeset.get_argument(changeset, :failure_class)) do
      pending_reply =
        pending_reply
        |> Map.put("status", "reply_retryable")
        |> Map.put("attempt_count", attempt_count + 1)
        |> Map.put("last_attempt_at", iso8601(Changeset.get_argument(changeset, :attempted_at)))
        |> Map.put("failure_class", Changeset.get_argument(changeset, :failure_class))

      put_pending_reply(changeset, pending_reply)
    else
      {:error, message} -> reply_state_error(changeset, message)
    end
  end

  defp mark_reply_sent_change(changeset, _context) do
    provider_message_id = Changeset.get_argument(changeset, :provider_message_id)

    case pending_reply_for_update(changeset, provider_message_id, @pending_reply_statuses) do
      {:ok, pending_reply} ->
        case reply_attempt_count(pending_reply) do
          {:ok, attempt_count} ->
            outbound_message_id = Changeset.get_argument(changeset, :outbound_message_id)

            if valid_provider_message_id?(outbound_message_id) do
              pending_reply =
                pending_reply
                |> Map.put("status", "reply_sent")
                |> Map.put("attempt_count", attempt_count + 1)
                |> Map.put(
                  "last_attempt_at",
                  iso8601(Changeset.get_argument(changeset, :sent_at))
                )
                |> Map.put("outbound_message_id", outbound_message_id)
                |> Map.put("ciphertext", nil)

              changeset
              |> put_pending_reply(pending_reply)
              |> Changeset.force_change_attribute(:last_outbound_message_id, outbound_message_id)
            else
              reply_state_error(changeset, "outbound provider is invalid")
            end

          {:error, message} ->
            reply_state_error(changeset, message)
        end

      {:already_terminal, "reply_sent"} ->
        changeset

      {:already_terminal, _status} ->
        reply_state_error(changeset, "reply delivery is terminal")

      {:error, message} ->
        reply_state_error(changeset, message)
    end
  end

  defp mark_reply_failed_change(changeset, _context) do
    provider_message_id = Changeset.get_argument(changeset, :provider_message_id)

    case pending_reply_for_update(changeset, provider_message_id, @pending_reply_statuses) do
      {:ok, pending_reply} ->
        with {:ok, attempt_count} <- reply_attempt_count(pending_reply),
             :ok <- validate_failure_class(Changeset.get_argument(changeset, :failure_class)) do
          failure_class = Changeset.get_argument(changeset, :failure_class)

          pending_reply =
            pending_reply
            |> Map.put("status", "reply_failed")
            |> Map.put("attempt_count", attempt_count + 1)
            |> Map.put(
              "last_attempt_at",
              iso8601(Changeset.get_argument(changeset, :failed_at))
            )
            |> Map.put("failure_class", failure_class)
            |> Map.put("ciphertext", nil)

          changeset
          |> put_pending_reply(pending_reply)
          |> Changeset.force_change_attribute(:needs_human, true)
          |> Changeset.force_change_attribute(:handoff_reason, failure_class)
        else
          {:error, message} -> reply_state_error(changeset, message)
        end

      {:already_terminal, "reply_failed"} ->
        changeset

      {:already_terminal, _status} ->
        reply_state_error(changeset, "reply delivery is terminal")

      {:error, message} ->
        reply_state_error(changeset, message)
    end
  end

  defp pending_reply_for_update(changeset, provider_message_id, allowed_statuses) do
    pending_reply = current_state_data(changeset) |> Map.get("pending_reply")

    cond do
      not valid_provider_message_id?(provider_message_id) ->
        {:error, "reply provider is invalid"}

      not is_map(pending_reply) ->
        {:error, "reply delivery state is missing"}

      Map.get(pending_reply, "provider_message_id") != provider_message_id ->
        {:error, "reply provider does not match"}

      Map.get(pending_reply, "status") in allowed_statuses ->
        {:ok, pending_reply}

      Map.get(pending_reply, "status") in @terminal_reply_statuses ->
        {:already_terminal, Map.get(pending_reply, "status")}

      true ->
        {:error, "reply delivery state is invalid"}
    end
  end

  defp reply_attempt_count(%{"attempt_count" => attempt_count})
       when is_integer(attempt_count) and attempt_count >= 0,
       do: {:ok, attempt_count}

  defp reply_attempt_count(_pending_reply), do: {:error, "reply attempt count is invalid"}

  defp put_pending_reply(changeset, pending_reply) do
    state_data =
      changeset
      |> current_state_data()
      |> Map.put("pending_reply", pending_reply)

    Changeset.force_change_attribute(changeset, :state_data, state_data)
  end

  defp current_state_data(changeset) do
    case Changeset.get_data(changeset, :state_data) do
      state_data when is_map(state_data) -> state_data
      _ -> %{}
    end
  end

  defp reply_state_error(changeset, message) do
    Changeset.add_error(changeset, field: :state_data, message: message)
  end

  defp valid_provider_message_id?(value), do: is_binary(value) and value != ""

  defp validate_failure_class(value) when value in @reply_failure_classes, do: :ok
  defp validate_failure_class(_value), do: {:error, "reply failure class is invalid"}

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

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
