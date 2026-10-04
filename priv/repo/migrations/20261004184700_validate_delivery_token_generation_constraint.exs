defmodule FastCheck.Repo.Migrations.ValidateDeliveryTokenGenerationConstraint do
  @moduledoc """
  P1E-B: validate `sales_ticket_issues_delivery_token_generation_non_negative`.

  `VALIDATE CONSTRAINT` uses `SHARE UPDATE EXCLUSIVE` and runs in a separate
  migration transaction from the `NOT VALID` add in `20261004184600`.
  """
  use Ecto.Migration

  @constraint "sales_ticket_issues_delivery_token_generation_non_negative"

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE sales_ticket_issues VALIDATE CONSTRAINT #{@constraint}")
  end

  def down do
    :ok
  end
end
