defmodule FastCheck.Repo.Migrations.HardenWhatsappDeliveryAttemptLifecycle do
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

  @legacy_delivery_attempt_statuses [
    "queued",
    "sent",
    "delivered",
    "failed",
    "fallback_required",
    "cancelled",
    "manual_review"
  ]

  @status_at_index_name :sales_delivery_status_events_attempt_status_at_idx
  @provider_message_index_name :sales_delivery_status_events_provider_message_id_idx

  def up do
    alter table(:sales_delivery_attempts) do
      add(:provider_accepted_at, :utc_datetime)
      add(:provider_status, :string)
      add(:provider_status_at, :utc_datetime)
      add(:read_at, :utc_datetime)
      add(:failed_at, :utc_datetime)
    end

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{quoted_values(@delivery_attempt_statuses)})"
      )
    )

    # Before this migration, the WhatsApp workers used `sent` for the local
    # result of an HTTP send. No callback path in the reviewed baseline could
    # have produced provider delivery evidence, so these rows are
    # deterministically re-labelled as provider acceptance. Rows without a
    # WAMID are included as historical local acceptance and remain visible for
    # operator follow-up; no delivery claim is manufactured.
    execute("""
    UPDATE sales_delivery_attempts
    SET status = 'provider_accepted',
        provider_status = 'accepted',
        provider_accepted_at = COALESCE(sent_at, inserted_at),
        provider_status_at = COALESCE(sent_at, inserted_at)
    WHERE provider = 'meta'
      AND channel = 'whatsapp'
      AND status = 'sent'
      AND provider_status IS NULL;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM sales_delivery_attempts
        WHERE provider = 'meta'
          AND channel = 'whatsapp'
          AND provider_message_id IS NOT NULL
        GROUP BY provider, channel, provider_message_id
        HAVING COUNT(*) > 1
      ) THEN
        RAISE EXCEPTION 'duplicate historical Meta WhatsApp provider message ids prevent deterministic reconciliation';
      END IF;
    END
    $$;
    """)

    create(
      unique_index(:sales_delivery_attempts, [:provider, :channel, :provider_message_id],
        name: :sales_delivery_attempts_meta_wamid_uidx,
        where: "provider = 'meta' AND channel = 'whatsapp' AND provider_message_id IS NOT NULL"
      )
    )

    create table(:sales_delivery_status_events) do
      add(:delivery_attempt_id, references(:sales_delivery_attempts, on_delete: :restrict),
        null: false
      )

      add(:provider, :string, null: false)
      add(:channel, :string, null: false)
      add(:provider_message_id, :string, null: false)
      add(:provider_status, :string, null: false)
      add(:provider_status_at, :utc_datetime, null: false)
      add(:provider_error_code, :string)
      add(:correlation_id, :string)

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(
        :sales_delivery_status_events,
        [:provider, :channel, :provider_message_id, :provider_status, :provider_status_at],
        name: :sales_delivery_status_events_provider_evidence_uidx
      )
    )

    create(
      index(:sales_delivery_status_events, [:delivery_attempt_id, :provider_status_at],
        name: @status_at_index_name
      )
    )

    create(
      index(:sales_delivery_status_events, [:provider_message_id],
        name: @provider_message_index_name
      )
    )
  end

  def down do
    drop_if_exists(
      index(:sales_delivery_status_events, [:provider_message_id],
        name: @provider_message_index_name
      )
    )

    drop_if_exists(
      index(:sales_delivery_status_events, [:delivery_attempt_id, :provider_status_at],
        name: @status_at_index_name
      )
    )

    drop_if_exists(
      unique_index(
        :sales_delivery_status_events,
        [:provider, :channel, :provider_message_id, :provider_status, :provider_status_at],
        name: :sales_delivery_status_events_provider_evidence_uidx
      )
    )

    drop_if_exists(table(:sales_delivery_status_events))

    drop_if_exists(
      index(:sales_delivery_attempts, [:provider, :channel, :provider_message_id],
        name: :sales_delivery_attempts_meta_wamid_uidx
      )
    )

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid))

    # A rollback necessarily loses the richer provider-evidence vocabulary,
    # but it must remain executable without deleting attempts. Preserve the
    # closest legacy success meaning before restoring the old constraint.
    execute("""
    UPDATE sales_delivery_attempts
    SET status = CASE status
      WHEN 'provider_accepted' THEN 'sent'
      WHEN 'read' THEN 'delivered'
      ELSE status
    END
    WHERE status IN ('provider_accepted', 'read');
    """)

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{quoted_values(@legacy_delivery_attempt_statuses)})"
      )
    )

    alter table(:sales_delivery_attempts) do
      remove(:failed_at)
      remove(:read_at)
      remove(:provider_status_at)
      remove(:provider_status)
      remove(:provider_accepted_at)
    end
  end

  defp quoted_values(values), do: Enum.map_join(values, ",", &"'#{&1}'")
end
