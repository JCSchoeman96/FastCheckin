defmodule FastCheck.Sales.PaymentAttempt do
  @moduledoc """
  Durable payment attempt skeleton for FastCheck Sales.

  VS-01C stores provider transaction attempt shape only. Paystack HTTP calls,
  verification, webhook handling, and workflow actions are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

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
  end

  field_policies do
    private_fields(:include)

    field_policy [
      :authorization_url,
      :access_code,
      :idempotency_key,
      :raw_initialize_response,
      :raw_verify_response
    ] do
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
end
