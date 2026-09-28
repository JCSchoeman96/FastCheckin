defmodule FastCheck.Repo.Migrations.CreateSalesTicketDeliveryIntents do
  use Ecto.Migration

  def up do
    create table(:sales_ticket_delivery_intents) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:ticket_issue_id, references(:sales_ticket_issues, on_delete: :restrict), null: false)
      add(:conversation_id, references(:sales_conversations, on_delete: :restrict), null: false)

      add(
        :ticket_resend_challenge_id,
        references(:sales_ticket_resend_challenges, on_delete: :restrict)
      )

      add(:purpose, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:failure_reason, :string)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime, null: false)
    end

    create(
      constraint(:sales_ticket_delivery_intents, :sales_ticket_delivery_intents_purpose_valid,
        check: "purpose IN ('initial_ticket_delivery', 'verified_ticket_resend')"
      )
    )

    create(
      constraint(:sales_ticket_delivery_intents, :sales_ticket_delivery_intents_status_valid,
        check:
          "status IN ('queued', 'provider_accepted', 'fallback_required', 'manual_review', 'cancelled')"
      )
    )

    create(
      constraint(
        :sales_ticket_delivery_intents,
        :sales_ticket_delivery_intents_purpose_challenge_valid,
        check: """
        (purpose = 'initial_ticket_delivery' AND ticket_resend_challenge_id IS NULL)
        OR
        (purpose = 'verified_ticket_resend' AND ticket_resend_challenge_id IS NOT NULL)
        """
      )
    )

    create(
      unique_index(:sales_ticket_delivery_intents, [:ticket_issue_id, :purpose],
        name: :sales_ticket_delivery_intents_initial_issue_purpose_uidx,
        where: "purpose = 'initial_ticket_delivery'"
      )
    )

    create(
      unique_index(:sales_ticket_delivery_intents, [:ticket_resend_challenge_id],
        name: :sales_ticket_delivery_intents_resend_challenge_uidx,
        where: "ticket_resend_challenge_id IS NOT NULL"
      )
    )

    create(index(:sales_ticket_delivery_intents, [:sales_order_id, :status]))
    create(index(:sales_ticket_delivery_intents, [:conversation_id, :status]))
    create(index(:sales_ticket_delivery_intents, [:ticket_issue_id]))

    alter table(:sales_delivery_attempts) do
      add(
        :ticket_delivery_intent_id,
        references(:sales_ticket_delivery_intents, on_delete: :restrict)
      )
    end

    create(
      unique_index(:sales_delivery_attempts, [:ticket_delivery_intent_id, :attempt_number],
        name: :sales_delivery_attempts_intent_attempt_uidx,
        where: "ticket_delivery_intent_id IS NOT NULL"
      )
    )

    create(
      index(:sales_delivery_attempts, [:ticket_delivery_intent_id, :inserted_at],
        name: :sales_delivery_attempts_intent_inserted_at_idx,
        where: "ticket_delivery_intent_id IS NOT NULL"
      )
    )

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid,
        check: """
        (delivery_reason IS NULL AND ticket_resend_challenge_id IS NULL)
        OR
        (
          delivery_reason IS NOT NULL
          AND delivery_reason = 'initial_ticket_delivery'
          AND ticket_resend_challenge_id IS NULL
        )
        OR
        (
          delivery_reason IS NOT NULL
          AND
          delivery_reason = 'verified_ticket_resend'
          AND ticket_resend_challenge_id IS NOT NULL
        )
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM sales_ticket_delivery_intents)
         OR EXISTS (
           SELECT 1 FROM sales_delivery_attempts
           WHERE delivery_reason = 'initial_ticket_delivery'
         ) THEN
        RAISE EXCEPTION 'cannot roll back durable ticket delivery evidence';
      END IF;
    END
    $$;
    """)

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid))

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid,
        check: """
        (delivery_reason IS NULL AND ticket_resend_challenge_id IS NULL)
        OR
        (
          delivery_reason IS NOT NULL
          AND delivery_reason = 'verified_ticket_resend'
          AND ticket_resend_challenge_id IS NOT NULL
        )
        """
      )
    )

    drop(
      index(:sales_delivery_attempts, [:ticket_delivery_intent_id, :inserted_at],
        name: :sales_delivery_attempts_intent_inserted_at_idx
      )
    )

    drop(
      index(:sales_delivery_attempts, [:ticket_delivery_intent_id, :attempt_number],
        name: :sales_delivery_attempts_intent_attempt_uidx
      )
    )

    alter table(:sales_delivery_attempts) do
      remove(:ticket_delivery_intent_id)
    end

    drop(index(:sales_ticket_delivery_intents, [:ticket_issue_id]))
    drop(index(:sales_ticket_delivery_intents, [:conversation_id, :status]))
    drop(index(:sales_ticket_delivery_intents, [:sales_order_id, :status]))

    drop(
      index(:sales_ticket_delivery_intents, [:ticket_resend_challenge_id],
        name: :sales_ticket_delivery_intents_resend_challenge_uidx
      )
    )

    drop(
      index(:sales_ticket_delivery_intents, [:ticket_issue_id, :purpose],
        name: :sales_ticket_delivery_intents_initial_issue_purpose_uidx
      )
    )

    drop(table(:sales_ticket_delivery_intents))
  end
end
