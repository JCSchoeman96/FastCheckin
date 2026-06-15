defmodule FastCheck.Repo.Migrations.CreateCheckoutAndPaymentResourceSkeletons do
  use Ecto.Migration

  @checkout_session_statuses [
    "created",
    "hold_attached",
    "payment_link_sent",
    "payment_started",
    "paid",
    "expired",
    "released",
    "failed",
    "manual_review"
  ]

  @payment_attempt_statuses [
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verified_success",
    "verified_amount_mismatch",
    "verified_currency_mismatch",
    "failed",
    "duplicate",
    "manual_review",
    "refunded"
  ]

  @payment_event_processing_statuses [
    "stored",
    "processing_started",
    "processed",
    "duplicate",
    "unmatched",
    "failed",
    "manual_review"
  ]

  def change do
    create table(:sales_checkout_sessions) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:status, :string, null: false)
      add(:redis_hold_key, :string)
      add(:hold_token, :string)
      add(:hold_quantity, :integer)
      add(:payment_link_sent_at, :utc_datetime)
      add(:released_at, :utc_datetime)
      add(:expired_at, :utc_datetime)
      add(:last_seen_at, :utc_datetime)
      add(:expires_at, :utc_datetime)
      add(:state_data, :map, null: false, default: %{})
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime)
    end

    create table(:sales_payment_attempts) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:provider, :string, null: false)
      add(:provider_reference, :string, null: false)
      add(:idempotency_key, :string)
      add(:authorization_url, :string)
      add(:access_code, :string)
      add(:status, :string, null: false)
      add(:provider_status, :string)
      add(:amount_cents, :integer, null: false)
      add(:currency, :string, null: false)
      add(:initialized_at, :utc_datetime)
      add(:provider_paid_at, :utc_datetime)
      add(:verified_at, :utc_datetime)
      add(:last_verified_at, :utc_datetime)
      add(:verification_attempt_count, :integer, null: false, default: 0)
      add(:failure_code, :string)
      add(:failure_message, :text)
      add(:manual_review_reason, :text)
      add(:raw_initialize_response, :map)
      add(:raw_verify_response, :map)

      timestamps(type: :utc_datetime)
    end

    create table(:sales_payment_events) do
      add(:provider, :string, null: false)
      add(:provider_event_id, :string)
      add(:provider_reference, :string)
      add(:event_type, :string, null: false)
      add(:signature_valid, :boolean)
      add(:payload_hash, :string)
      add(:raw_payload, :map)
      add(:received_at, :utc_datetime)
      add(:processed_at, :utc_datetime)
      add(:processing_status, :string, null: false)
      add(:processing_attempt_count, :integer, null: false, default: 0)
      add(:last_processing_error, :text)
      add(:last_processing_error_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:sales_checkout_sessions, :sales_checkout_sessions_status_valid,
        check: "status IN (#{quoted_values(@checkout_session_statuses)})"
      )
    )

    create(
      constraint(:sales_checkout_sessions, :sales_checkout_sessions_hold_quantity_non_negative,
        check: "hold_quantity IS NULL OR hold_quantity >= 0"
      )
    )

    create(
      constraint(:sales_payment_attempts, :sales_payment_attempts_status_valid,
        check: "status IN (#{quoted_values(@payment_attempt_statuses)})"
      )
    )

    create(
      constraint(:sales_payment_attempts, :sales_payment_attempts_amount_cents_non_negative,
        check: "amount_cents >= 0"
      )
    )

    create(
      constraint(
        :sales_payment_attempts,
        :sales_payment_attempts_verification_attempt_count_non_negative,
        check: "verification_attempt_count >= 0"
      )
    )

    create(
      constraint(:sales_payment_attempts, :sales_payment_attempts_currency_format,
        check: "currency ~ '^[A-Z]{3}$'"
      )
    )

    create(
      constraint(:sales_payment_events, :sales_payment_events_processing_status_valid,
        check: "processing_status IN (#{quoted_values(@payment_event_processing_statuses)})"
      )
    )

    create(
      constraint(
        :sales_payment_events,
        :sales_payment_events_processing_attempt_count_non_negative,
        check: "processing_attempt_count >= 0"
      )
    )

    create(
      constraint(:sales_payment_events, :sales_payment_events_dedupe_identity_present,
        check: "provider_event_id IS NOT NULL OR payload_hash IS NOT NULL"
      )
    )

    create(
      unique_index(:sales_checkout_sessions, [:sales_order_id],
        name: :sales_checkout_sessions_sales_order_id_uidx
      )
    )

    create(
      unique_index(:sales_checkout_sessions, [:redis_hold_key],
        name: :sales_checkout_sessions_redis_hold_key_uidx,
        where: "redis_hold_key IS NOT NULL"
      )
    )

    create(
      index(:sales_checkout_sessions, [:status, :expires_at],
        name: :sales_checkout_sessions_status_expires_at_idx
      )
    )

    create(
      index(:sales_checkout_sessions, [:sales_order_id, :status],
        name: :sales_checkout_sessions_sales_order_id_status_idx
      )
    )

    create(
      unique_index(:sales_payment_attempts, [:provider, :provider_reference],
        name: :sales_payment_attempts_provider_reference_uidx
      )
    )

    create(
      index(:sales_payment_attempts, [:sales_order_id, :status],
        name: :sales_payment_attempts_sales_order_id_status_idx
      )
    )

    create(
      index(:sales_payment_attempts, [:provider, :status],
        name: :sales_payment_attempts_provider_status_idx
      )
    )

    create(
      index(:sales_payment_attempts, [:last_verified_at],
        name: :sales_payment_attempts_last_verified_at_idx
      )
    )

    create(
      unique_index(:sales_payment_events, [:provider, :provider_event_id],
        name: :sales_payment_events_provider_event_id_uidx,
        where: "provider_event_id IS NOT NULL"
      )
    )

    create(
      unique_index(:sales_payment_events, [:provider, :payload_hash],
        name: :sales_payment_events_provider_payload_hash_uidx,
        where: "provider_event_id IS NULL"
      )
    )

    create(
      index(:sales_payment_events, [:provider_reference],
        name: :sales_payment_events_provider_reference_idx
      )
    )

    create(
      index(:sales_payment_events, [:processing_status, :inserted_at],
        name: :sales_payment_events_processing_status_inserted_at_idx
      )
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
