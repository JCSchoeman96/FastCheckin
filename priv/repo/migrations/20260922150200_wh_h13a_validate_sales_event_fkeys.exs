defmodule FastCheck.Repo.Migrations.WhH13aValidateSalesEventFkeys do
  @moduledoc """
  WH-H13A phase 3: validate Sales Event foreign keys added as `NOT VALID`.

  `VALIDATE CONSTRAINT` takes a `SHARE UPDATE EXCLUSIVE` lock and scans the table.
  """
  use Ecto.Migration

  @orders_fk "sales_orders_event_id_fkey"
  @offers_fk "sales_ticket_offers_event_id_fkey"

  def up do
    execute("ALTER TABLE sales_orders VALIDATE CONSTRAINT #{@orders_fk}")
    execute("ALTER TABLE sales_ticket_offers VALIDATE CONSTRAINT #{@offers_fk}")
  end

  def down do
    :ok
  end
end
