defmodule FastCheck.Repo.Migrations.AddResendAuditFieldsToDeliveryAttempts do
  use Ecto.Migration

  def up do
    alter table(:sales_delivery_attempts) do
      add(:delivery_reason, :string)

      add(
        :ticket_resend_challenge_id,
        references(:sales_ticket_resend_challenges, on_delete: :restrict)
      )
    end

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid,
        check: "delivery_reason IS NULL OR delivery_reason = 'verified_ticket_resend'"
      )
    )

    create(
      index(:sales_delivery_attempts, [:ticket_resend_challenge_id],
        name: :sales_delivery_attempts_resend_challenge_id_idx,
        where: "ticket_resend_challenge_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:sales_delivery_attempts, [:ticket_resend_challenge_id],
        name: :sales_delivery_attempts_resend_challenge_id_idx
      )
    )

    drop(constraint(:sales_delivery_attempts, :sales_delivery_attempts_delivery_reason_valid))

    alter table(:sales_delivery_attempts) do
      remove(:ticket_resend_challenge_id)
      remove(:delivery_reason)
    end
  end
end
