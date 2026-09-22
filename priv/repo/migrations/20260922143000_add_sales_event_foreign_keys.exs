defmodule FastCheck.Repo.Migrations.AddSalesEventForeignKeys do
  @moduledoc """
  Align Sales root `event_id` columns with `events.id` (bigint) and enforce ON DELETE RESTRICT.

  Prerequisite for fail-closed archived event removal (#437 / WH-H13).
  """
  use Ecto.Migration

  @orders_fk "sales_orders_event_id_fkey"
  @offers_fk "sales_ticket_offers_event_id_fkey"

  def up do
    execute("""
    ALTER TABLE sales_orders
      ALTER COLUMN event_id TYPE bigint USING event_id::bigint
    """)

    execute("""
    ALTER TABLE sales_ticket_offers
      ALTER COLUMN event_id TYPE bigint USING event_id::bigint
    """)

    execute("""
    ALTER TABLE sales_orders
      ADD CONSTRAINT #{@orders_fk}
      FOREIGN KEY (event_id) REFERENCES events(id)
      ON DELETE RESTRICT
      NOT VALID
    """)

    execute("ALTER TABLE sales_orders VALIDATE CONSTRAINT #{@orders_fk}")

    execute("""
    ALTER TABLE sales_ticket_offers
      ADD CONSTRAINT #{@offers_fk}
      FOREIGN KEY (event_id) REFERENCES events(id)
      ON DELETE RESTRICT
      NOT VALID
    """)

    execute("ALTER TABLE sales_ticket_offers VALIDATE CONSTRAINT #{@offers_fk}")
  end

  def down do
    execute("ALTER TABLE sales_orders DROP CONSTRAINT IF EXISTS #{@orders_fk}")
    execute("ALTER TABLE sales_ticket_offers DROP CONSTRAINT IF EXISTS #{@offers_fk}")

    execute("""
    ALTER TABLE sales_orders
      ALTER COLUMN event_id TYPE integer USING event_id::integer
    """)

    execute("""
    ALTER TABLE sales_ticket_offers
      ALTER COLUMN event_id TYPE integer USING event_id::integer
    """)
  end
end
