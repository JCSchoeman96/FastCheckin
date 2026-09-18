defmodule FastCheck.Repo.Migrations.AddDeliveryAttemptProviderAcceptanceTruth do
  use Ecto.Migration

  @delivery_attempt_statuses [
    "queued",
    "provider_accepted",
    "sent",
    "delivered",
    "read",
    "failed",
    "fallback_required",
    "cancelled",
    "manual_review"
  ]

  def up do
    # Abort before changing the table if exact future WAMID correlation would be
    # ambiguous. The migration must not choose a winner or delete a row.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM sales_delivery_attempts
        WHERE provider = 'meta'
          AND channel = 'whatsapp'
          AND provider_message_id IS NOT NULL
          AND btrim(provider_message_id) <> ''
        GROUP BY provider_message_id
        HAVING count(*) > 1
      ) THEN
        RAISE EXCEPTION 'duplicate usable Meta WhatsApp provider_message_id values prevent WH-H01 migration';
      END IF;
    END
    $$;
    """)

    # Existing delivered/read rows without a WAMID cannot be classified as
    # provider evidence safely. Abort before adding the invariant rather than
    # manufacturing a correlation or silently rewriting the historical row.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM sales_delivery_attempts
        WHERE provider = 'meta'
          AND channel = 'whatsapp'
          AND status IN ('delivered', 'read')
          AND (
            provider_message_id IS NULL
            OR btrim(provider_message_id) = ''
          )
      ) THEN
        RAISE EXCEPTION 'Meta WhatsApp delivered/read rows without usable provider_message_id prevent WH-H01 migration';
      END IF;
    END
    $$;
    """)

    alter table(:sales_delivery_attempts) do
      add(:provider_accepted_at, :utc_datetime)
      add(:provider_status, :string)
      add(:provider_status_at, :utc_datetime)
      add(:read_at, :utc_datetime)
      add(:failed_at, :utc_datetime)
      add(:lock_version, :integer, null: false, default: 1)
    end

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{quoted_values(@delivery_attempt_statuses)})"
      )
    )

    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'provider_accepted',
        provider_status = 'accepted',
        provider_accepted_at = COALESCE(sent_at, inserted_at),
        provider_status_at = COALESCE(sent_at, inserted_at),
        sent_at = NULL
    WHERE status = 'sent'
      AND provider = 'meta'
      AND channel = 'whatsapp'
      AND provider_message_id IS NOT NULL
      AND btrim(provider_message_id) <> '';
    """)

    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'manual_review',
        failure_reason = 'legacy_delivery_outcome_unverified',
        fallback_channel = 'manual_review',
        sent_at = NULL
    WHERE status = 'sent'
      AND provider = 'meta'
      AND channel = 'whatsapp'
      AND (
        provider_message_id IS NULL
        OR btrim(provider_message_id) = ''
      );
    """)

    create(
      constraint(
        :sales_delivery_attempts,
        :sales_delivery_attempts_meta_whatsapp_provider_message_id_valid,
        check: """
        COALESCE(provider, '') <> 'meta'
        OR COALESCE(channel, '') <> 'whatsapp'
        OR status NOT IN ('provider_accepted', 'sent', 'delivered', 'read')
        OR (
          provider_message_id IS NOT NULL
          AND btrim(provider_message_id) <> ''
        )
        """
      )
    )

    create(
      unique_index(
        :sales_delivery_attempts,
        [:provider, :channel, :provider_message_id],
        name: :sales_delivery_attempts_meta_whatsapp_wamid_uidx,
        where:
          "provider = 'meta' AND channel = 'whatsapp' AND provider_message_id IS NOT NULL AND btrim(provider_message_id) <> ''"
      )
    )

    create table(:sales_delivery_status_events) do
      add(
        :delivery_attempt_id,
        references(:sales_delivery_attempts, on_delete: :restrict),
        null: false
      )

      add(:provider, :string, null: false)
      add(:channel, :string, null: false)
      add(:provider_message_id, :string, null: false)
      add(:provider_status, :string, null: false)
      add(:provider_status_at, :utc_datetime, null: false)
      add(:provider_error_code, :string)
      add(:raw_payload_hash, :string)
      add(:correlation_id, :string)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(
        :sales_delivery_status_events,
        [:provider, :channel, :provider_message_id, :provider_status, :provider_status_at],
        name: :sales_delivery_status_events_identity_uidx
      )
    )

    create(
      index(:sales_delivery_status_events, [:delivery_attempt_id, :provider_status_at],
        name: :sales_delivery_status_events_attempt_status_at_idx
      )
    )
  end

  def down do
    # Rolling back drops the immutable evidence table and therefore loses any
    # H01A evidence rows. Rich read/acceptance states are mapped to the closest
    # legacy vocabulary, and provider acceptance time returns to sent_at.
    drop(
      index(:sales_delivery_status_events, [:delivery_attempt_id, :provider_status_at],
        name: :sales_delivery_status_events_attempt_status_at_idx
      )
    )

    drop(
      index(
        :sales_delivery_status_events,
        [:provider, :channel, :provider_message_id, :provider_status, :provider_status_at],
        name: :sales_delivery_status_events_identity_uidx
      )
    )

    drop(table(:sales_delivery_status_events))

    drop(
      index(:sales_delivery_attempts, [:provider, :channel, :provider_message_id],
        name: :sales_delivery_attempts_meta_whatsapp_wamid_uidx
      )
    )

    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'delivered',
        delivered_at = COALESCE(delivered_at, read_at)
    WHERE status = 'read';
    """)

    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'sent',
        sent_at = COALESCE(sent_at, provider_accepted_at)
    WHERE status = 'provider_accepted';
    """)

    drop(
      constraint(
        :sales_delivery_attempts,
        :sales_delivery_attempts_meta_whatsapp_provider_message_id_valid
      )
    )

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check:
          "status IN ('queued','sent','delivered','failed','fallback_required','cancelled','manual_review')"
      )
    )

    alter table(:sales_delivery_attempts) do
      remove(:provider_accepted_at)
      remove(:provider_status)
      remove(:provider_status_at)
      remove(:read_at)
      remove(:failed_at)
      remove(:lock_version)
    end
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
