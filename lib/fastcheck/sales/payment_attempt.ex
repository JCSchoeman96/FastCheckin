defmodule FastCheck.Sales.PaymentAttempt do
  @moduledoc """
  Durable payment attempt for FastCheck Sales.

  VS-06B adds initialization workflow actions. VS-07B adds verification workflow
  actions. Paystack HTTP calls remain in the service layer only.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Ash.Changeset
  alias FastCheck.Sales.StateTransitionSupport

  postgres do
    table("sales_payment_attempts")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_provider_reference: "sales_payment_attempts_provider_reference_uidx"
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

    read :get_by_provider_reference do
      get?(true)

      argument :provider, :string do
        allow_nil?(false)
      end

      argument :provider_reference, :string do
        allow_nil?(false)
      end

      filter(
        expr(provider == ^arg(:provider) and provider_reference == ^arg(:provider_reference))
      )
    end

    read :get_active_by_idempotency_key do
      get?(true)

      argument :idempotency_key, :string do
        allow_nil?(false)
      end

      filter(
        expr(
          idempotency_key == ^arg(:idempotency_key) and
            status in ["initializing", "initialized"]
        )
      )
    end

    create :create_initializing do
      accept([
        :sales_order_id,
        :provider,
        :provider_reference,
        :idempotency_key,
        :amount_cents,
        :currency
      ])

      change(set_attribute(:status, "initializing"))
      change(set_attribute(:verification_attempt_count, 0))
      change(&record_create_transition/2)
    end

    update :mark_initialized do
      require_atomic?(false)

      accept([
        :authorization_url,
        :access_code,
        :raw_initialize_response,
        :initialized_at
      ])

      change(&transition_status(&1, &2, "initialized", allowed_from: ["initializing"]))
    end

    update :mark_failed do
      require_atomic?(false)

      accept([:failure_code, :failure_message])

      change(&transition_status(&1, &2, "failed", allowed_from: ["initializing"]))
    end

    update :mark_manual_review do
      require_atomic?(false)

      accept([:manual_review_reason, :failure_code, :failure_message])
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

    update :mark_verification_started do
      require_atomic?(false)
      accept([])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        cond do
          from_state == "verification_started" ->
            changeset

          from_state in ["initialized", "authorization_url_sent", "webhook_received", "failed"] ->
            count = Changeset.get_data(changeset, :verification_attempt_count) || 0

            transition_status(
              changeset,
              context,
              "verification_started",
              allowed_from: nil,
              extra_attrs: %{verification_attempt_count: count + 1}
            )

          true ->
            Changeset.add_error(changeset,
              field: :status,
              message: "invalid transition from #{from_state}"
            )
        end
      end)
    end

    update :mark_verified_success do
      require_atomic?(false)

      accept([
        :provider_status,
        :provider_paid_at,
        :verified_at,
        :last_verified_at,
        :raw_verify_response
      ])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "verified_success" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "verified_success",
            allowed_from: ["verification_started"]
          )
        end
      end)
    end

    update :mark_verified_amount_mismatch do
      require_atomic?(false)
      accept([:provider_status, :last_verified_at, :raw_verify_response])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "verified_amount_mismatch" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "verified_amount_mismatch",
            allowed_from: ["verification_started"]
          )
        end
      end)
    end

    update :mark_verified_currency_mismatch do
      require_atomic?(false)
      accept([:provider_status, :last_verified_at, :raw_verify_response])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "verified_currency_mismatch" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "verified_currency_mismatch",
            allowed_from: ["verification_started"]
          )
        end
      end)
    end

    update :mark_verification_failed do
      require_atomic?(false)
      accept([:provider_status, :failure_code, :failure_message, :last_verified_at])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "failed" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "failed",
            allowed_from: ["verification_started"]
          )
        end
      end)
    end

    update :mark_duplicate do
      require_atomic?(false)
      accept([:failure_code, :failure_message])

      change(fn changeset, context ->
        from_state = Changeset.get_data(changeset, :status)

        if from_state == "duplicate" do
          changeset
        else
          transition_status(
            changeset,
            context,
            "duplicate",
            allowed_from: nil
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
      authorize_if({FastCheck.Sales.PolicyChecks.EventAllowed, relationship_path: [:order]})
    end

    policy action([
             :create_initializing,
             :mark_initialized,
             :mark_failed,
             :mark_manual_review
           ]) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin]})
    end

    policy action([
             :create_initializing,
             :mark_initialized,
             :mark_failed,
             :mark_manual_review
           ]) do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.EventAllowed,
         relationship_path: [:order], actor_types: [:admin]}
      )
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [
      :authorization_url,
      :access_code,
      :idempotency_key,
      :raw_initialize_response
    ] do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin]})
    end

    field_policy [:raw_verify_response] do
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    field_policy :* do
      authorize_if(
        {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system, :admin, :operator]}
      )
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :provider, :string do
      allow_nil?(false)
    end

    attribute :provider_reference, :string do
      allow_nil?(false)
    end

    attribute(:idempotency_key, :string)
    attribute(:authorization_url, :string, sensitive?: true)
    attribute(:access_code, :string, sensitive?: true)

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:provider_status, :string)

    attribute :amount_cents, :integer do
      allow_nil?(false)
    end

    attribute :currency, :string do
      allow_nil?(false)
    end

    attribute(:initialized_at, :utc_datetime)
    attribute(:provider_paid_at, :utc_datetime)
    attribute(:verified_at, :utc_datetime)
    attribute(:last_verified_at, :utc_datetime)

    attribute :verification_attempt_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute(:failure_code, :string)
    attribute(:failure_message, :string)
    attribute(:manual_review_reason, :string)

    attribute(:raw_initialize_response, :map, sensitive?: true)
    attribute(:raw_verify_response, :map, sensitive?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :order, FastCheck.Sales.Order do
      source_attribute(:sales_order_id)
      attribute_type(:integer)
      allow_nil?(false)
    end
  end

  identities do
    identity(:unique_provider_reference, [:provider, :provider_reference])
  end

  defp record_create_transition(changeset, context) do
    Changeset.after_action(changeset, fn _changeset, record ->
      StateTransitionSupport.record!(
        %{
          entity_type: "PaymentAttempt",
          entity_id: Integer.to_string(record.id),
          from_state: nil,
          to_state: record.status,
          metadata: transition_metadata(context, record),
          correlation_id: transition_correlation_id(context),
          idempotency_key: record.idempotency_key,
          source: "payment_attempt.create_initializing"
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
                 entity_type: "PaymentAttempt",
                 entity_id: Integer.to_string(record.id),
                 from_state: from_state,
                 to_state: record.status,
                 reason: reason || record.manual_review_reason,
                 metadata: transition_metadata(context, record),
                 correlation_id: transition_correlation_id(context),
                 idempotency_key: record.idempotency_key,
                 source: "payment_attempt.#{record.status}"
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
      provider: record.provider,
      provider_reference: record.provider_reference
    }

    context
    |> Map.get(:transition_metadata, %{})
    |> Map.merge(base)
  end
end
