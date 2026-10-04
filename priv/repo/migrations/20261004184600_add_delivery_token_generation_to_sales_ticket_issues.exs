defmodule FastCheck.Repo.Migrations.AddDeliveryTokenGenerationToSalesTicketIssues do
  @moduledoc """
  P1E-B: add `delivery_token_generation` with a non-negative CHECK added as `NOT VALID`.

  Constraint validation runs in `20261004184700_validate_delivery_token_generation_constraint`.
  """
  use Ecto.Migration

  @constraint "sales_ticket_issues_delivery_token_generation_non_negative"

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    alter table(:sales_ticket_issues) do
      add(:delivery_token_generation, :integer, null: false, default: 0)
    end

    execute("""
    ALTER TABLE sales_ticket_issues
      ADD CONSTRAINT #{@constraint}
      CHECK (delivery_token_generation >= 0)
      NOT VALID
    """)
  end

  def down do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    execute("ALTER TABLE sales_ticket_issues DROP CONSTRAINT IF EXISTS #{@constraint}")

    alter table(:sales_ticket_issues) do
      remove(:delivery_token_generation)
    end
  end
end
