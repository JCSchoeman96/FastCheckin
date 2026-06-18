defmodule FastCheck.Sales.Order do
  @moduledoc """
  Durable money-bearing Sales order for FastCheck Sales checkout.

  VS-05 adds named workflow actions and state-transition audit for checkout core.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Sales.StateTransitionSupport

  postgres do
    table("sales_orders")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_public_reference: "sales_orders_public_reference_uidx",
      unique_idempotency_key: "sales_orders_idempotency_key_uidx"
    )
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

    read :get_by_public_reference do
      get?(true)

      argument :public_reference, :string do
        allow_nil?(false)
      end

      filter(expr(public_reference == ^arg(:public_reference)))
    end

    read :get_by_idempotency_key do
      get?(true)

      argument :idempotency_key, :string do
        allow_nil?(false)
      end

      filter(expr(idempotency_key == ^arg(:idempotency_key)))
    end

    create :create_draft do
      accept([
        :public_reference,
        :event_id,
        :buyer_name,
        :buyer_phone,
        :buyer_email,
        :source_channel,
        :total_amount_cents,
        :currency,
        :idempotency_key,
        :expires_at,
        :whatsapp_conversation_id
      ])

      change(set_attribute(:status, "draft"))

      validate(
        present([:public_reference, :event_id, :source_channel, :total_amount_cents, :currency])
      )

      change(&record_create_transition/2)
    end

    update :confirm_checkout do
      require_atomic?(false)
      accept([])
      validate(fn changeset, context -> confirm_checkout_preconditions(changeset, context) end)
    end

    update :mark_awaiting_payment do
      require_atomic?(false)
      accept([:expires_at])
      change(&transition_status(&1, &2, "awaiting_payment", allowed_from: ["draft"]))
    end

    update :mark_payment_pending do
      require_atomic?(false)
      accept([])
      change(&transition_status(&1, &2, "payment_pending", allowed_from: ["awaiting_payment"]))
    end

    update :mark_paid_unverified do
      require_atomic?(false)
      accept([])

      change(
        &transition_status(&1, &2, "paid_unverified",
          allowed_from: ["awaiting_payment", "payment_pending"]
        )
      )
    end

    update :expire_order do
      require_atomic?(false)
      accept([])

      change(
        &transition_status(&1, &2, "expired",
          allowed_from: ["draft", "awaiting_payment", "payment_pending"],
          extra_attrs: %{expired_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        )
      )
    end

    update :cancel_order do
      require_atomic?(false)
      accept([:manual_review_reason])
      argument(:reason, :string)

      change(fn changeset, context ->
        reason =
          Changeset.get_argument(changeset, :reason) ||
            Changeset.get_attribute(changeset, :manual_review_reason)

        transition_status(
          changeset,
          context,
          "cancelled",
          allowed_from: ["draft", "awaiting_payment", "payment_pending"],
          reason: reason,
          extra_attrs: %{
            cancelled_at: DateTime.utc_now() |> DateTime.truncate(:second),
            manual_review_reason: reason
          }
        )
      end)
    end

    update :mark_manual_review do
      require_atomic?(false)
      accept([:manual_review_reason, :last_error_code, :last_error_message])
      argument(:reason, :string)

      change(fn changeset, context ->
        reason =
          Changeset.get_argument(changeset, :reason) ||
            Changeset.get_attribute(changeset, :manual_review_reason)

        from_state = Changeset.get_data(changeset, :status)

        if from_state == "manual_review" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "manual_review",
            allowed_from: nil,
            reason: reason,
            extra_attrs: %{manual_review_reason: reason}
          )
        end
      end)
    end

    update :mark_paid_verified do
      require_atomic?(false)
      accept([])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "paid_verified" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "paid_verified",
            allowed_from: ["awaiting_payment", "payment_pending", "paid_unverified"],
            extra_attrs: %{paid_at: DateTime.utc_now() |> DateTime.truncate(:second)}
          )
        end
      end)
    end

    update :mark_paid_verified_from_late_recovery do
      require_atomic?(false)
      accept([])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "paid_verified" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "paid_verified",
            allowed_from: ["awaiting_payment", "payment_pending", "paid_unverified", "expired"],
            extra_attrs: %{paid_at: DateTime.utc_now() |> DateTime.truncate(:second)}
          )
        end
      end)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin, :operator]})
    end

    policy action_type(:read) do
      authorize_if(FastCheck.Sales.PolicyChecks.EventAllowed)
    end

    policy action([:create_draft, :confirm_checkout, :cancel_order, :mark_manual_review]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([:create_draft, :confirm_checkout, :cancel_order, :mark_manual_review]) do
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, actor_types: [:admin]})
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [:buyer_name, :buyer_phone, :buyer_email] do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin]})
    end

    field_policy :* do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin, :operator]}
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :public_reference, :string do
      allow_nil?(false)
    end

    attribute :event_id, :integer do
      allow_nil?(false)
    end

    attribute(:buyer_name, :string)
    attribute(:buyer_phone, :string)
    attribute(:buyer_email, :string)

    attribute :source_channel, :string do
      allow_nil?(false)
    end

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute :total_amount_cents, :integer do
      allow_nil?(false)
    end

    attribute :currency, :string do
      allow_nil?(false)
    end

    attribute(:whatsapp_conversation_id, :string)
    attribute(:idempotency_key, :string)
    attribute(:expires_at, :utc_datetime)
    attribute(:paid_at, :utc_datetime)
    attribute(:fulfillment_queued_at, :utc_datetime)
    attribute(:ticket_issued_at, :utc_datetime)
    attribute(:cancelled_at, :utc_datetime)
    attribute(:expired_at, :utc_datetime)
    attribute(:refunded_at, :utc_datetime)
    attribute(:manual_review_reason, :string)
    attribute(:last_error_code, :string)
    attribute(:last_error_message, :string)

    attribute :lock_version, :integer do
      allow_nil?(false)
      default(1)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many :order_lines, FastCheck.Sales.OrderLine do
      destination_attribute(:sales_order_id)
    end

    has_one :checkout_session, FastCheck.Sales.CheckoutSession do
      destination_attribute(:sales_order_id)
    end

    has_many :payment_attempts, FastCheck.Sales.PaymentAttempt do
      destination_attribute(:sales_order_id)
    end

    has_many :ticket_issues, FastCheck.Sales.TicketIssue do
      destination_attribute(:sales_order_id)
    end

    has_many :delivery_attempts, FastCheck.Sales.DeliveryAttempt do
      destination_attribute(:sales_order_id)
    end

    belongs_to :conversation, FastCheck.Sales.Conversation do
      source_attribute(:sales_conversation_id)
      attribute_type(:integer)
      allow_nil?(true)
    end
  end

  identities do
    identity(:unique_public_reference, [:public_reference])

    identity :unique_idempotency_key, [:idempotency_key] do
      where(expr(not is_nil(idempotency_key)))
    end
  end

  defp confirm_checkout_preconditions(changeset, _context) do
    status = Changeset.get_data(changeset, :status)
    total = Changeset.get_data(changeset, :total_amount_cents)

    cond do
      status != "draft" ->
        {:error, field: :status, message: "must be draft"}

      is_nil(total) or total <= 0 ->
        {:error, field: :total_amount_cents, message: "must be positive"}

      true ->
        :ok
    end
  end

  defp record_create_transition(changeset, context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      StateTransitionSupport.record!(
        %{
          entity_type: "Order",
          entity_id: Integer.to_string(record.id),
          from_state: nil,
          to_state: "draft",
          metadata: transition_metadata(context, record),
          correlation_id: transition_correlation_id(context),
          idempotency_key: record.idempotency_key,
          source: "order.create_draft"
        },
        context
      )

      {:ok, record}
    end)
  end

  defp transition_status(changeset, context, to_status, opts) do
    from_state = Changeset.get_data(changeset, :status)
    allowed_from = Keyword.get(opts, :allowed_from)
    reason = Keyword.get(opts, :reason)
    extra_attrs = Keyword.get(opts, :extra_attrs, %{})

    changeset =
      if allowed_from && from_state not in allowed_from do
        Changeset.add_error(changeset,
          field: :status,
          message: "invalid transition from #{from_state}"
        )
      else
        changeset
      end

    if changeset.valid? do
      changeset =
        changeset
        |> Changeset.force_change_attribute(:status, to_status)
        |> then(fn cs ->
          Enum.reduce(
            extra_attrs,
            cs,
            &Changeset.force_change_attribute(&2, elem(&1, 0), elem(&1, 1))
          )
        end)

      Changeset.after_action(changeset, fn _changeset, record ->
        case StateTransitionSupport.record!(
               %{
                 entity_type: "Order",
                 entity_id: Integer.to_string(record.id),
                 from_state: from_state,
                 to_state: record.status,
                 reason: reason || record.manual_review_reason,
                 metadata: transition_metadata(context, record),
                 correlation_id: transition_correlation_id(context),
                 idempotency_key: record.idempotency_key,
                 source: "order.#{record.status}"
               },
               context
             ) do
          {:ok, _} -> {:ok, record}
          {:error, error} -> {:error, error}
        end
      end)
    else
      changeset
    end
  end

  defp transition_correlation_id(context) do
    actor = Map.get(context, :actor, %{})
    Map.get(context, :correlation_id) || Map.get(actor, :correlation_id)
  end

  defp transition_metadata(context, record) do
    base = %{
      source_channel: record.source_channel,
      public_reference: record.public_reference
    }

    context
    |> Map.get(:transition_metadata, %{})
    |> Map.merge(base)
  end
end
