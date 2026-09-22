defmodule FastCheck.Repo.Migrations.WhH13aAlignSalesEventIdTypes do
  @moduledoc """
  WH-H13A phase 1: align Sales `event_id` column types with `events.id` (bigint).

  Deployment note: `ALTER COLUMN ... TYPE bigint` rewrites each Sales table and holds
  an `ACCESS EXCLUSIVE` lock for the duration of the rewrite. Production row counts,
  index rebuild behavior, and maintenance-window approval are **not** inferable from CI;
  treat this migration as requiring an explicit ops sign-off before production apply.

  The DDL uses a transaction-local 5-second `lock_timeout`; failure to acquire a
  required lock within that period aborts the migration. Operators must drain
  conflicting readers and writers rather than repeatedly increasing the timeout.
  Production backup and maintenance-window approval remain required.

  Orphan `event_id` values must be resolved before this migration runs.
  """
  use Ecto.Migration

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")
    assert_no_orphan_sales_event_ids!()

    execute("""
    ALTER TABLE sales_orders
      ALTER COLUMN event_id TYPE bigint USING event_id::bigint
    """)

    execute("""
    ALTER TABLE sales_ticket_offers
      ALTER COLUMN event_id TYPE bigint USING event_id::bigint
    """)
  end

  def down do
    repo().query!("SET LOCAL lock_timeout = '5s'")
    assert_sales_event_ids_fit_integer!()

    execute("""
    ALTER TABLE sales_orders
      ALTER COLUMN event_id TYPE integer USING event_id::integer
    """)

    execute("""
    ALTER TABLE sales_ticket_offers
      ALTER COLUMN event_id TYPE integer USING event_id::integer
    """)
  end

  defp assert_no_orphan_sales_event_ids! do
    orphan_orders =
      repo().query!("""
      SELECT COUNT(*) FROM sales_orders o
      WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = o.event_id)
      """).rows

    orphan_offers =
      repo().query!("""
      SELECT COUNT(*) FROM sales_ticket_offers o
      WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = o.event_id)
      """).rows

    orders = List.first(orphan_orders) |> List.first()
    offers = List.first(orphan_offers) |> List.first()

    if orders != 0 or offers != 0 do
      raise "WH-H13A orphan preflight failed: sales_orders=#{orders} sales_ticket_offers=#{offers}"
    end
  end

  defp assert_sales_event_ids_fit_integer! do
    max_order =
      repo().query!("SELECT COALESCE(MAX(event_id), 0) FROM sales_orders").rows
      |> List.first()
      |> List.first()

    max_offer =
      repo().query!("SELECT COALESCE(MAX(event_id), 0) FROM sales_ticket_offers").rows
      |> List.first()
      |> List.first()

    max_value = max(max_order, max_offer)

    if max_value > 2_147_483_647 do
      raise "WH-H13A down blocked: sales event_id #{max_value} exceeds integer range"
    end
  end
end
