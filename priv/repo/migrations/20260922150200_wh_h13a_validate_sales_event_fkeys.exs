defmodule FastCheck.Repo.Migrations.WhH13aValidateSalesEventFkeys do
  @moduledoc """
  WH-H13A phase 3: validate Sales Event foreign keys added as `NOT VALID`.

  `VALIDATE CONSTRAINT` takes a `SHARE UPDATE EXCLUSIVE` lock and scans the table.
  The DDL uses a transaction-local 5-second `lock_timeout`; failure to acquire a
  required lock within that period aborts the migration. Operators must drain
  conflicting readers and writers rather than repeatedly increasing the timeout.
  Production backup and maintenance-window approval remain required.
  """
  use Ecto.Migration

  @orders_fk "sales_orders_event_id_fkey"
  @offers_fk "sales_ticket_offers_event_id_fkey"

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    execute("ALTER TABLE sales_orders VALIDATE CONSTRAINT #{@orders_fk}")
    execute("ALTER TABLE sales_ticket_offers VALIDATE CONSTRAINT #{@offers_fk}")
  end

  def down do
    :ok
  end
end
