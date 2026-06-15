defmodule FastCheck.Repo.Migrations.CreateTicketAndDeliveryResourceSkeletons do
  use Ecto.Migration

  @ticket_issue_statuses ["pending", "issued", "revoked", "manual_review"]

  @delivery_attempt_statuses [
    "queued",
    "sent",
    "delivered",
    "failed",
    "fallback_required",
    "cancelled",
    "manual_review"
  ]

  @delivery_channels ["whatsapp", "email", "admin", "system"]

  def change do
    create table(:sales_ticket_issues) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:sales_order_line_id, references(:sales_order_lines, on_delete: :restrict), null: false)
      add(:line_item_sequence, :integer, null: false)
      add(:attendee_id, :integer)
      add(:ticket_code, :string)
      add(:qr_token_hash, :string)
      add(:delivery_token_hash, :string)
      add(:delivery_token_expires_at, :utc_datetime)
      add(:status, :string, null: false)
      add(:scanner_status, :string)
      add(:last_scanner_sync_version, :integer)
      add(:issued_at, :utc_datetime)
      add(:revoked_at, :utc_datetime)
      add(:revocation_reason, :text)

      timestamps(type: :utc_datetime)
    end

    create table(:sales_delivery_attempts) do
      add(:sales_order_id, references(:sales_orders, on_delete: :restrict), null: false)
      add(:ticket_issue_id, references(:sales_ticket_issues, on_delete: :restrict), null: false)
      add(:channel, :string, null: false)
      add(:provider, :string)
      add(:recipient, :string)
      add(:status, :string, null: false)
      add(:template_name, :string)
      add(:within_whatsapp_window, :boolean)
      add(:provider_message_id, :string)
      add(:attempt_number, :integer, null: false)
      add(:provider_error_code, :string)
      add(:provider_error_message, :text)
      add(:failure_reason, :text)
      add(:fallback_channel, :string)
      add(:correlation_id, :string)
      add(:sent_at, :utc_datetime)
      add(:delivered_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:sales_ticket_issues, :sales_ticket_issues_status_valid,
        check: "status IN (#{quoted_values(@ticket_issue_statuses)})"
      )
    )

    create(
      constraint(:sales_ticket_issues, :sales_ticket_issues_line_item_sequence_positive,
        check: "line_item_sequence >= 1"
      )
    )

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_status_valid,
        check: "status IN (#{quoted_values(@delivery_attempt_statuses)})"
      )
    )

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_channel_valid,
        check: "channel IN (#{quoted_values(@delivery_channels)})"
      )
    )

    create(
      constraint(:sales_delivery_attempts, :sales_delivery_attempts_attempt_number_positive,
        check: "attempt_number >= 1"
      )
    )

    create(
      unique_index(:sales_ticket_issues, [:ticket_code],
        name: :sales_ticket_issues_ticket_code_uidx,
        where: "ticket_code IS NOT NULL"
      )
    )

    create(
      unique_index(:sales_ticket_issues, [:sales_order_line_id, :line_item_sequence],
        name: :sales_ticket_issues_order_line_sequence_uidx
      )
    )

    create(
      unique_index(:sales_ticket_issues, [:attendee_id],
        name: :sales_ticket_issues_attendee_id_uidx,
        where: "attendee_id IS NOT NULL"
      )
    )

    create(
      index(:sales_ticket_issues, [:sales_order_id],
        name: :sales_ticket_issues_sales_order_id_idx
      )
    )

    create(
      index(:sales_ticket_issues, [:sales_order_line_id],
        name: :sales_ticket_issues_sales_order_line_id_idx
      )
    )

    create(index(:sales_ticket_issues, [:status], name: :sales_ticket_issues_status_idx))

    create(
      index(:sales_ticket_issues, [:scanner_status],
        name: :sales_ticket_issues_scanner_status_idx
      )
    )

    create(
      index(:sales_delivery_attempts, [:sales_order_id, :status],
        name: :sales_delivery_attempts_sales_order_id_status_idx
      )
    )

    create(
      index(:sales_delivery_attempts, [:ticket_issue_id, :status],
        name: :sales_delivery_attempts_ticket_issue_id_status_idx
      )
    )

    create(
      index(:sales_delivery_attempts, [:provider_message_id],
        name: :sales_delivery_attempts_provider_message_id_idx
      )
    )

    create(
      index(:sales_delivery_attempts, [:channel, :status, :inserted_at],
        name: :sales_delivery_attempts_channel_status_inserted_at_idx
      )
    )

    create(
      index(:sales_delivery_attempts, [:correlation_id],
        name: :sales_delivery_attempts_correlation_id_idx
      )
    )
  end

  defp quoted_values(values) do
    Enum.map_join(values, ",", &"'#{&1}'")
  end
end
