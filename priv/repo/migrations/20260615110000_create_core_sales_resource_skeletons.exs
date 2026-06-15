defmodule FastCheck.Repo.Migrations.CreateCoreSalesResourceSkeletons do
  use Ecto.Migration

  @order_statuses [
    "draft",
    "awaiting_payment",
    "payment_pending",
    "paid_unverified",
    "paid_verified",
    "fulfillment_queued",
    "ticket_issued",
    "partially_issued",
    "manual_review",
    "cancelled",
    "expired",
    "refunded"
  ]

  @source_channels ["web", "whatsapp", "admin", "system", "test"]
  @actor_types ["system", "admin", "operator", "customer_session"]

  def change do
    create table(:sales_ticket_offers) do
      add(:event_id, :integer, null: false)
      add(:name, :string, null: false)
      add(:ticket_type, :string, null: false)
      add(:price_cents, :integer, null: false)
      add(:currency, :string, null: false)
      add(:configured_quantity_available, :integer, null: false)
      add(:initial_quantity, :integer, null: false)
      add(:max_per_order, :integer, null: false)
      add(:sales_enabled, :boolean, null: false, default: false)
      add(:sales_channel, :string, null: false)
      add(:starts_at, :utc_datetime, null: false)
      add(:ends_at, :utc_datetime, null: false)
      add(:lock_version, :integer, null: false, default: 1)
      add(:archived_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create table(:sales_orders) do
      add(:public_reference, :string, null: false)
      add(:event_id, :integer, null: false)
      add(:buyer_name, :string)
      add(:buyer_phone, :string)
      add(:buyer_email, :string)
      add(:source_channel, :string, null: false)
      add(:status, :string, null: false)
      add(:total_amount_cents, :integer, null: false)
      add(:currency, :string, null: false)
      add(:whatsapp_conversation_id, :string)
      add(:idempotency_key, :string)
      add(:expires_at, :utc_datetime)
      add(:paid_at, :utc_datetime)
      add(:fulfillment_queued_at, :utc_datetime)
      add(:ticket_issued_at, :utc_datetime)
      add(:cancelled_at, :utc_datetime)
      add(:expired_at, :utc_datetime)
      add(:refunded_at, :utc_datetime)
      add(:manual_review_reason, :text)
      add(:last_error_code, :string)
      add(:last_error_message, :text)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime)
    end

    create table(:sales_order_lines) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:ticket_offer_id, references(:sales_ticket_offers, on_delete: :restrict), null: false)
      add(:line_number, :integer, null: false)
      add(:ticket_type, :string, null: false)
      add(:offer_name_snapshot, :string, null: false)
      add(:event_name_snapshot, :string, null: false)
      add(:quantity, :integer, null: false)
      add(:unit_amount_cents, :integer, null: false)
      add(:total_amount_cents, :integer, null: false)
      add(:currency, :string, null: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create table(:sales_state_transitions) do
      add(:entity_type, :string, null: false)
      add(:entity_id, :string, null: false)
      add(:from_state, :string)
      add(:to_state, :string, null: false)
      add(:reason, :text)
      add(:actor_type, :string, null: false)
      add(:actor_id, :string)
      add(:metadata, :map, null: false, default: %{})
      add(:correlation_id, :string)
      add(:request_id, :string)
      add(:idempotency_key, :string)
      add(:source, :string)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_price_cents_non_negative,
        check: "price_cents >= 0"
      )
    )

    create(
      constraint(
        :sales_ticket_offers,
        :sales_ticket_offers_configured_quantity_available_non_negative,
        check: "configured_quantity_available >= 0"
      )
    )

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_initial_quantity_non_negative,
        check: "initial_quantity >= 0"
      )
    )

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_max_per_order_positive,
        check: "max_per_order > 0"
      )
    )

    create(
      constraint(:sales_ticket_offers, :sales_ticket_offers_currency_format,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:sales_orders, :sales_orders_total_amount_cents_non_negative,
        check: "total_amount_cents >= 0"
      )
    )

    create(
      constraint(:sales_orders, :sales_orders_currency_format, check: "currency ~ '^[A-Z]{3}$'")
    )

    create(
      constraint(:sales_orders, :sales_orders_status_valid,
        check: "status IN (#{quoted_values(@order_statuses)})"
      )
    )

    create(
      constraint(:sales_orders, :sales_orders_source_channel_valid,
        check: "source_channel IN (#{quoted_values(@source_channels)})"
      )
    )

    create(
      constraint(:sales_order_lines, :sales_order_lines_line_number_positive,
        check: "line_number > 0"
      )
    )

    create(
      constraint(:sales_order_lines, :sales_order_lines_quantity_positive, check: "quantity > 0")
    )

    create(
      constraint(:sales_order_lines, :sales_order_lines_unit_amount_cents_non_negative,
        check: "unit_amount_cents >= 0"
      )
    )

    create(
      constraint(:sales_order_lines, :sales_order_lines_total_amount_cents_non_negative,
        check: "total_amount_cents >= 0"
      )
    )

    create(
      constraint(:sales_order_lines, :sales_order_lines_currency_format,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:sales_state_transitions, :sales_state_transitions_actor_type_valid,
        check: "actor_type IN (#{quoted_values(@actor_types)})"
      )
    )

    create(
      unique_index(:sales_ticket_offers, [:event_id, :name],
        name: :sales_ticket_offers_active_name_uidx,
        where: "archived_at IS NULL"
      )
    )

    create(
      index(:sales_ticket_offers, [:event_id, :sales_enabled, :starts_at, :ends_at],
        name: :sales_ticket_offers_event_sales_window_idx
      )
    )

    create(
      unique_index(:sales_orders, [:public_reference], name: :sales_orders_public_reference_uidx)
    )

    create(
      unique_index(:sales_orders, [:idempotency_key],
        name: :sales_orders_idempotency_key_uidx,
        where: "idempotency_key IS NOT NULL"
      )
    )

    create(
      index(:sales_orders, [:event_id, :status, :inserted_at],
        name: :sales_orders_event_status_inserted_at_idx
      )
    )

    create(
      index(:sales_orders, [:event_id, :source_channel, :inserted_at],
        name: :sales_orders_event_source_inserted_at_idx
      )
    )

    create(index(:sales_orders, [:buyer_phone], name: :sales_orders_buyer_phone_idx))
    create(index(:sales_orders, [:expires_at, :status], name: :sales_orders_expires_status_idx))

    create(
      index(:sales_orders, [:status, :fulfillment_queued_at],
        name: :sales_orders_status_fulfillment_queued_at_idx
      )
    )

    create(
      index(:sales_order_lines, [:sales_order_id], name: :sales_order_lines_sales_order_id_idx)
    )

    create(
      index(:sales_order_lines, [:ticket_offer_id], name: :sales_order_lines_ticket_offer_id_idx)
    )

    create(
      unique_index(:sales_order_lines, [:sales_order_id, :line_number],
        name: :sales_order_lines_order_line_number_uidx
      )
    )

    create(
      index(:sales_state_transitions, [:entity_type, :entity_id, :inserted_at],
        name: :sales_state_transitions_entity_idx
      )
    )

    create(
      index(:sales_state_transitions, [:actor_type, :actor_id, :inserted_at],
        name: :sales_state_transitions_actor_idx
      )
    )

    create(
      index(:sales_state_transitions, [:correlation_id],
        name: :sales_state_transitions_correlation_id_idx
      )
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
