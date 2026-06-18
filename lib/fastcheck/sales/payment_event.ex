defmodule FastCheck.Sales.PaymentEvent do
  @moduledoc """
  Durable raw payment provider event for FastCheck Sales.

  VS-07A adds webhook ingestion storage. Verification and order/payment mutation
  are deferred to later slices.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("sales_payment_events")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_provider_event_id: "sales_payment_events_provider_event_id_uidx",
      unique_provider_payload_hash: "sales_payment_events_provider_payload_hash_uidx"
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

    read :get_by_provider_event_id do
      get?(true)

      argument :provider, :string do
        allow_nil?(false)
      end

      argument :provider_event_id, :string do
        allow_nil?(false)
      end

      filter(expr(provider == ^arg(:provider) and provider_event_id == ^arg(:provider_event_id)))
    end

    read :get_by_provider_payload_hash do
      get?(true)

      argument :provider, :string do
        allow_nil?(false)
      end

      argument :payload_hash, :string do
        allow_nil?(false)
      end

      filter(
        expr(
          provider == ^arg(:provider) and is_nil(provider_event_id) and
            payload_hash == ^arg(:payload_hash)
        )
      )
    end

    create :store_webhook_event do
      accept([
        :provider,
        :provider_event_id,
        :provider_reference,
        :event_type,
        :signature_valid,
        :payload_hash,
        :raw_payload,
        :received_at,
        :processing_status,
        :processing_attempt_count
      ])

      transaction?(false)
    end
  end

  policies do
    bypass {FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]} do
      authorize_if(always())
    end

    policy action(:store_webhook_event) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:system]})
    end

    policy action_type(:read) do
      access_type(:strict)
      authorize_if({FastCheck.Sales.PolicyChecks.ActorTypeIn, actor_types: [:admin, :operator]})
    end
  end

  field_policies do
    private_fields(:include)

    field_policy [:raw_payload, :last_processing_error] do
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

    attribute(:provider_event_id, :string)
    attribute(:provider_reference, :string)

    attribute :event_type, :string do
      allow_nil?(false)
    end

    attribute(:signature_valid, :boolean)
    attribute(:payload_hash, :string)
    attribute(:raw_payload, :map, sensitive?: true)

    attribute(:received_at, :utc_datetime)
    attribute(:processed_at, :utc_datetime)

    attribute :processing_status, :string do
      allow_nil?(false)
    end

    attribute :processing_attempt_count, :integer do
      allow_nil?(false)
      default(0)
    end

    attribute(:last_processing_error, :string)
    attribute(:last_processing_error_at, :utc_datetime)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity :unique_provider_event_id, [:provider, :provider_event_id] do
      where(expr(not is_nil(provider_event_id)))
    end

    identity :unique_provider_payload_hash, [:provider, :payload_hash] do
      where(expr(is_nil(provider_event_id)))
    end
  end
end
