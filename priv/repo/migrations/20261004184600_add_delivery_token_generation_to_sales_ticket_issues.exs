defmodule FastCheck.Repo.Migrations.AddDeliveryTokenGenerationToSalesTicketIssues do
  use Ecto.Migration

  def change do
    alter table(:sales_ticket_issues) do
      add(:delivery_token_generation, :integer, null: false, default: 0)
    end

    create(
      constraint(
        :sales_ticket_issues,
        :sales_ticket_issues_delivery_token_generation_non_negative,
        check: "delivery_token_generation >= 0"
      )
    )
  end
end
