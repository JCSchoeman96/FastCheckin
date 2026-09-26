defmodule FastCheck.Sales.SalesEventForeignKeysTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events
  alias FastCheck.Fixtures
  alias FastCheck.Repo

  @orders_fk "sales_orders_event_id_fkey"
  @offers_fk "sales_ticket_offers_event_id_fkey"

  test "sales root tables reference events with ON DELETE RESTRICT" do
    assert_foreign_key("sales_orders", "event_id", "events")
    assert_foreign_key("sales_ticket_offers", "event_id", "events")
    assert_foreign_key_delete_rule("sales_orders", "event_id", "RESTRICT")
    assert_foreign_key_delete_rule("sales_ticket_offers", "event_id", "RESTRICT")
  end

  test "named sales event foreign key constraints exist in catalog" do
    assert constraint_exists?(@orders_fk)
    assert constraint_exists?(@offers_fk)
  end

  test "sales_orders.event_id rejects nonexistent events" do
    missing_id = 9_999_999_991

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           idempotency_key, inserted_at, updated_at)
        VALUES
          ('fk-test-order', $1, 'test', 'draft', 100, 'ZAR', 'fk-test-idem',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [missing_id]
      )
    end)
  end

  test "sales_ticket_offers.event_id rejects nonexistent events" do
    missing_id = 9_999_999_992

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, 'FK Offer', 'GA', 100, 'ZAR', 10, 10, 1, false, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '1 day',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        """,
        [missing_id]
      )
    end)
  end

  test "cannot delete event while a sales order references it" do
    event = Fixtures.create_event()
    _order_id = insert_sales_order!(event.id)

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      Repo.query!("DELETE FROM events WHERE id = $1", [event.id])
    end)

    assert Repo.get!(FastCheck.Events.Event, event.id)
  end

  test "cannot delete event while a ticket offer references it" do
    event = Fixtures.create_event()
    _offer_id = insert_offer!(event.id)

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      Repo.query!("DELETE FROM events WHERE id = $1", [event.id])
    end)

    assert Repo.get!(FastCheck.Events.Event, event.id)
  end

  test "orphan sales event_id preflight is zero in test database" do
    assert [[0]] =
             Repo.query!("""
             SELECT COUNT(*) FROM sales_orders o
             WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = o.event_id)
             """).rows

    assert [[0]] =
             Repo.query!("""
             SELECT COUNT(*) FROM sales_ticket_offers o
             WHERE NOT EXISTS (SELECT 1 FROM events e WHERE e.id = o.event_id)
             """).rows
  end

  test "deleted event cannot receive new sales_order rows (orphan prevention)" do
    event = Fixtures.create_event()
    assert {:ok, _} = Events.archive_event(event.id)
    assert {:ok, _} = Events.remove_archived_event(event.id)

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      insert_sales_order!(event.id)
    end)
  end

  test "deleted event cannot receive new sales_ticket_offer rows (orphan prevention)" do
    event = Fixtures.create_event()
    assert {:ok, _} = Events.archive_event(event.id)
    assert {:ok, _} = Events.remove_archived_event(event.id)

    assert_db_error(~r/foreign key|violates foreign key constraint/i, fn ->
      insert_offer!(event.id)
    end)
  end

  defp insert_offer!(event_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, 'FK Offer', 'GA', 100, 'ZAR', 10, 10, 1, false, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '1 day',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id]
      )

    id
  end

  defp insert_sales_order!(event_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, source_channel, status, total_amount_cents, currency,
           idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, $2, 'test', 'draft', 100, 'ZAR', $3,
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          "FK-#{System.unique_integer([:positive])}",
          event_id,
          "fk-idem-#{System.unique_integer([:positive])}"
        ]
      )

    id
  end

  defp assert_foreign_key(table_name, column_name, foreign_table_name) do
    assert [[^table_name, ^column_name, ^foreign_table_name]] =
             Repo.query!(
               """
               SELECT tc.table_name, kcu.column_name, ccu.table_name AS foreign_table_name
               FROM information_schema.table_constraints AS tc
               JOIN information_schema.key_column_usage AS kcu
                 ON tc.constraint_name = kcu.constraint_name
               JOIN information_schema.constraint_column_usage AS ccu
                 ON ccu.constraint_name = tc.constraint_name
               WHERE tc.constraint_type = 'FOREIGN KEY'
                 AND tc.table_name = $1
                 AND kcu.column_name = $2
                 AND ccu.table_name = $3
               """,
               [table_name, column_name, foreign_table_name]
             ).rows
  end

  defp assert_foreign_key_delete_rule(table_name, column_name, delete_rule) do
    assert [[^delete_rule]] =
             Repo.query!(
               """
               SELECT rc.delete_rule
               FROM information_schema.referential_constraints rc
               JOIN information_schema.key_column_usage kcu
                 ON rc.constraint_name = kcu.constraint_name
               WHERE kcu.table_name = $1 AND kcu.column_name = $2
               """,
               [table_name, column_name]
             ).rows
  end

  defp constraint_exists?(name) do
    Repo.query!(
      """
      SELECT 1 FROM pg_constraint WHERE conname = $1
      """,
      [name]
    ).rows != []
  end

  defp assert_db_error(pattern, fun) do
    assert_raise Postgrex.Error, pattern, fun
  end
end
