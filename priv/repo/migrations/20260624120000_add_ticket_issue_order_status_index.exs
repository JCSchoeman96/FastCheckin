defmodule FastCheck.Repo.Migrations.AddTicketIssueOrderStatusIndex do
  @moduledoc """
  VS-15A: composite index for bounded issued-ticket lookups during order-level revocation.
  """

  use Ecto.Migration

  def change do
    create(
      index(:sales_ticket_issues, [:sales_order_id, :status],
        name: :sales_ticket_issues_sales_order_id_status_idx
      )
    )
  end
end
