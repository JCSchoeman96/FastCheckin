defmodule FastCheck.Repo.Migrations.WhH13aAddSalesEventFkeysNotValid do
  @moduledoc """
  WH-H13A phase 2: add restrictive Event foreign keys with `NOT VALID` (short lock).

  Requires phase 1 (`20260922150000_wh_h13a_align_sales_event_id_types`) applied first.
  Validation runs in a separate migration.

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

    execute("""
    ALTER TABLE sales_orders
      ADD CONSTRAINT #{@orders_fk}
      FOREIGN KEY (event_id) REFERENCES events(id)
      ON DELETE RESTRICT
      NOT VALID
    """)

    execute("""
    ALTER TABLE sales_ticket_offers
      ADD CONSTRAINT #{@offers_fk}
      FOREIGN KEY (event_id) REFERENCES events(id)
      ON DELETE RESTRICT
      NOT VALID
    """)
  end

  def down do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    execute("ALTER TABLE sales_orders DROP CONSTRAINT IF EXISTS #{@orders_fk}")
    execute("ALTER TABLE sales_ticket_offers DROP CONSTRAINT IF EXISTS #{@offers_fk}")
  end
end
