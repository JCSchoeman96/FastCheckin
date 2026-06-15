defmodule FastCheck.Sales.PaymentEvent do
  @moduledoc """
  Durable raw payment provider event skeleton for FastCheck Sales.

  VS-01C stores webhook/event audit shape only. Signature verification,
  processing workers, and order/payment mutation are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

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
