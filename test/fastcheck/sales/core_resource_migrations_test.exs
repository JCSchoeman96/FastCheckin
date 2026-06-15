defmodule FastCheck.Sales.CoreResourceMigrationsTest do
  use FastCheck.DataCase, async: true

  @sales_tables [
    "sales_order_lines",
    "sales_orders",
    "sales_state_transitions",
    "sales_ticket_offers"
  ]

  test "creates exactly the VS-01B sales tables" do
    existing_tables =
      Repo.query!(
        """
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name LIKE 'sales_%'
        ORDER BY table_name
        """,
        []
      ).rows
      |> List.flatten()

    assert existing_tables == @sales_tables
  end

  test "sales tables expose required columns" do
    assert_columns("sales_ticket_offers", [
      "id",
      "event_id",
      "name",
      "ticket_type",
      "price_cents",
      "currency",
      "configured_quantity_available",
      "initial_quantity",
      "max_per_order",
      "sales_enabled",
      "sales_channel",
      "starts_at",
      "ends_at",
      "lock_version",
      "archived_at",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_orders", [
      "id",
      "public_reference",
      "event_id",
      "buyer_name",
      "buyer_phone",
      "buyer_email",
      "source_channel",
      "status",
      "total_amount_cents",
      "currency",
      "whatsapp_conversation_id",
      "idempotency_key",
      "expires_at",
      "paid_at",
      "fulfillment_queued_at",
      "ticket_issued_at",
      "cancelled_at",
      "expired_at",
      "refunded_at",
      "manual_review_reason",
      "last_error_code",
      "last_error_message",
      "lock_version",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_order_lines", [
      "id",
      "sales_order_id",
      "ticket_offer_id",
      "line_number",
      "ticket_type",
      "offer_name_snapshot",
      "event_name_snapshot",
      "quantity",
      "unit_amount_cents",
      "total_amount_cents",
      "currency",
      "metadata",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_state_transitions", [
      "id",
      "entity_type",
      "entity_id",
      "from_state",
      "to_state",
      "reason",
      "actor_type",
      "actor_id",
      "metadata",
      "correlation_id",
      "request_id",
      "idempotency_key",
      "source",
      "inserted_at"
    ])
  end

  test "money and quantity fields use integer columns" do
    assert_column_type("sales_ticket_offers", "price_cents", "integer")
    assert_column_type("sales_orders", "total_amount_cents", "integer")
    assert_column_type("sales_order_lines", "quantity", "integer")
    assert_column_type("sales_order_lines", "unit_amount_cents", "integer")
    assert_column_type("sales_order_lines", "total_amount_cents", "integer")
  end

  test "required indexes and partial unique indexes exist" do
    assert_index("sales_ticket_offers_active_name_uidx")
    assert_index("sales_ticket_offers_event_sales_window_idx")
    assert_index("sales_orders_public_reference_uidx")
    assert_index("sales_orders_idempotency_key_uidx")
    assert_index("sales_orders_event_status_inserted_at_idx")
    assert_index("sales_orders_event_source_inserted_at_idx")
    assert_index("sales_orders_buyer_phone_idx")
    assert_index("sales_orders_expires_status_idx")
    assert_index("sales_orders_status_fulfillment_queued_at_idx")
    assert_index("sales_order_lines_sales_order_id_idx")
    assert_index("sales_order_lines_ticket_offer_id_idx")
    assert_index("sales_order_lines_order_line_number_uidx")
    assert_index("sales_state_transitions_entity_idx")
    assert_index("sales_state_transitions_actor_idx")
    assert_index("sales_state_transitions_correlation_id_idx")

    assert_index_where("sales_ticket_offers_active_name_uidx", "archived_at IS NULL")
    assert_index_where("sales_orders_idempotency_key_uidx", "idempotency_key IS NOT NULL")
  end

  test "order lines enforce foreign keys" do
    assert_foreign_key("sales_order_lines", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_order_lines", "ticket_offer_id", "sales_ticket_offers")
  end

  test "database constraints reject unsafe skeleton data" do
    assert_db_error(~r/sales_ticket_offers_price_cents_non_negative/, fn ->
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_channel, starts_at, ends_at, inserted_at, updated_at)
        VALUES
          (1, 'General', 'general', -1, 'ZAR', 10, 10, 1, 'whatsapp', now(), now(), now(), now())
        """,
        []
      )
    end)

    assert_db_error(~r/sales_orders_status_valid/, fn ->
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, inserted_at, updated_at)
        VALUES
          ('FC-INVALID', 1, 'Buyer', 'whatsapp', 'not_a_state', 100, 'ZAR', now(), now())
        """,
        []
      )
    end)

    assert_db_error(~r/sales_order_lines_quantity_positive/, fn ->
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           inserted_at, updated_at)
        VALUES
          (999, 999, 1, 'general', 'General', 'Event', 0, 100, 100, 'ZAR', now(), now())
        """,
        []
      )
    end)
  end

  defp assert_columns(table_name, expected_columns) do
    actual_columns =
      Repo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = $1
        """,
        [table_name]
      ).rows
      |> List.flatten()
      |> MapSet.new()

    for column <- expected_columns do
      assert column in actual_columns, "#{table_name} is missing #{column}"
    end

    refute "organization_id" in actual_columns,
           "#{table_name} must not include organization_id in VS-01B"
  end

  defp assert_column_type(table_name, column_name, data_type) do
    assert [[^data_type]] =
             Repo.query!(
               """
               SELECT data_type
               FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name = $1
                 AND column_name = $2
               """,
               [table_name, column_name]
             ).rows
  end

  defp assert_index(index_name) do
    assert [[^index_name]] =
             Repo.query!(
               """
               SELECT indexname
               FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = $1
               """,
               [index_name]
             ).rows
  end

  defp assert_index_where(index_name, expected_where) do
    assert [[indexdef]] =
             Repo.query!(
               """
               SELECT indexdef
               FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = $1
               """,
               [index_name]
             ).rows

    assert indexdef =~ expected_where
  end

  defp assert_foreign_key(table_name, column_name, foreign_table_name) do
    assert [[^table_name, ^column_name, ^foreign_table_name]] =
             Repo.query!(
               """
               SELECT
                 tc.table_name,
                 kcu.column_name,
                 ccu.table_name AS foreign_table_name
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

  defp assert_db_error(pattern, fun) do
    assert_raise Postgrex.Error, pattern, fun
  end
end
