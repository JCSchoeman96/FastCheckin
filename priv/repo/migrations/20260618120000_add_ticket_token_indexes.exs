defmodule FastCheck.Repo.Migrations.AddTicketTokenIndexes do
  use Ecto.Migration

  def change do
    create(
      unique_index(:sales_ticket_issues, [:qr_token_hash],
        name: :sales_ticket_issues_qr_token_hash_uidx,
        where: "qr_token_hash IS NOT NULL"
      )
    )

    create(
      unique_index(:sales_ticket_issues, [:delivery_token_hash],
        name: :sales_ticket_issues_delivery_token_hash_uidx,
        where: "delivery_token_hash IS NOT NULL"
      )
    )

    create(
      index(:sales_ticket_issues, [:delivery_token_expires_at],
        name: :sales_ticket_issues_delivery_token_expires_at_idx,
        where: "delivery_token_hash IS NOT NULL"
      )
    )

    create(
      index(:sales_ticket_issues, [:status, :delivery_token_expires_at],
        name: :sales_ticket_issues_status_delivery_token_expires_at_idx
      )
    )
  end
end
