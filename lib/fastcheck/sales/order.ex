defmodule FastCheck.Sales.Order do
  @moduledoc """
  Durable money-bearing Sales order skeleton.

  VS-01B defines the persistent shape only. State workflow actions, payment
  verification, fulfillment, and ticket issuance are intentionally absent.
  """

  use Ash.Resource,
    domain: FastCheck.Sales,
    data_layer: AshPostgres.DataLayer

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
  end

  identities do
    identity(:unique_public_reference, [:public_reference])

    identity :unique_idempotency_key, [:idempotency_key] do
      where(expr(not is_nil(idempotency_key)))
    end
  end
end
