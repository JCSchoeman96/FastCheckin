defmodule FastCheck.Repo.Migrations.CreateSalesTicketResendChallenges do
  use Ecto.Migration

  @statuses ["pending", "verified", "consumed", "expired", "blocked", "manual_review"]

  def change do
    create table(:sales_ticket_resend_challenges) do
      add(:public_id, :string, null: false)
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict))
      add(:ticket_issue_id, references(:sales_ticket_issues, on_delete: :restrict))
      add(:conversation_id, references(:sales_conversations, on_delete: :restrict))
      add(:request_email_hash, :string, null: false)
      add(:request_name_hash, :string)
      add(:source_hash, :string)
      add(:candidate_hash, :string)
      add(:otp_hash, :string)
      add(:status, :string, null: false)
      add(:failure_reason, :string)
      add(:failed_attempt_count, :integer, null: false, default: 0)
      add(:expires_at, :utc_datetime, null: false)
      add(:verified_at, :utc_datetime)
      add(:consumed_at, :utc_datetime)
      add(:locked_until, :utc_datetime)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:sales_ticket_resend_challenges, :sales_ticket_resend_challenges_status_valid,
        check: "status IN (#{quoted_values(@statuses)})"
      )
    )

    create(
      constraint(
        :sales_ticket_resend_challenges,
        :ticket_resend_challenges_failed_attempt_count_non_negative,
        check: "failed_attempt_count >= 0"
      )
    )

    create(
      unique_index(:sales_ticket_resend_challenges, [:public_id],
        name: :sales_ticket_resend_challenges_public_id_uidx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:request_email_hash, :inserted_at],
        name: :ticket_resend_challenges_email_inserted_at_idx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:source_hash, :inserted_at],
        name: :ticket_resend_challenges_source_inserted_at_idx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:candidate_hash, :inserted_at],
        name: :ticket_resend_challenges_candidate_inserted_at_idx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:status, :expires_at],
        name: :ticket_resend_challenges_status_expires_at_idx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:sales_order_id],
        name: :sales_ticket_resend_challenges_sales_order_id_idx
      )
    )

    create(
      index(:sales_ticket_resend_challenges, [:ticket_issue_id],
        name: :sales_ticket_resend_challenges_ticket_issue_id_idx
      )
    )

    execute(
      """
      CREATE INDEX IF NOT EXISTS sales_orders_lower_buyer_email_status_inserted_at_idx
      ON sales_orders (lower(buyer_email), status, inserted_at DESC)
      WHERE buyer_email IS NOT NULL
      """,
      "DROP INDEX IF EXISTS sales_orders_lower_buyer_email_status_inserted_at_idx"
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
