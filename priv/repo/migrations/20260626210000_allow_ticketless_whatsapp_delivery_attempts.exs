defmodule FastCheck.Repo.Migrations.AllowTicketlessWhatsappDeliveryAttempts do
  use Ecto.Migration

  def change do
    alter table(:sales_delivery_attempts) do
      modify(
        :ticket_issue_id,
        references(:sales_ticket_issues, on_delete: :restrict),
        null: true,
        from: {references(:sales_ticket_issues, on_delete: :restrict), null: false}
      )
    end

    create(
      index(:sales_delivery_attempts, [:sales_order_id, :channel, :status, :inserted_at],
        name: :sales_delivery_attempts_order_channel_status_inserted_at_idx
      )
    )
  end
end
