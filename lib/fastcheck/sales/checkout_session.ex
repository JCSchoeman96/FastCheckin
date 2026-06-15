defmodule FastCheck.Sales.CheckoutSession do
  @moduledoc """
  Durable checkout session skeleton for FastCheck Sales.

  VS-01C stores checkout intent and Redis hold references only. Inventory
  mutation, payment initialization, and session workflow actions are deferred.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("sales_checkout_sessions")
    repo(FastCheck.Repo)

    identity_index_names(
      unique_order: "sales_checkout_sessions_sales_order_id_uidx",
      unique_redis_hold_key: "sales_checkout_sessions_redis_hold_key_uidx"
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

    attribute :status, :string do
      allow_nil?(false)
    end

    attribute(:redis_hold_key, :string)
    attribute(:hold_token, :string, sensitive?: true)
    attribute(:hold_quantity, :integer)
    attribute(:payment_link_sent_at, :utc_datetime)
    attribute(:released_at, :utc_datetime)
    attribute(:expired_at, :utc_datetime)
    attribute(:last_seen_at, :utc_datetime)
    attribute(:expires_at, :utc_datetime)

    attribute :state_data, :map do
      allow_nil?(false)
      default(%{})
    end

    attribute :lock_version, :integer do
      allow_nil?(false)
      default(1)
    end

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
    identity(:unique_order, [:sales_order_id])

    identity :unique_redis_hold_key, [:redis_hold_key] do
      where(expr(not is_nil(redis_hold_key)))
    end
  end
end
