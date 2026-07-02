defmodule FastCheck.Sales.ConversationResourceMigrationsTest do
  use FastCheck.DataCase, async: true

  @sales_tables [
    "sales_checkout_sessions",
    "sales_conversations",
    "sales_delivery_attempts",
    "sales_manual_review_actions",
    "sales_order_lines",
    "sales_orders",
    "sales_payment_attempts",
    "sales_payment_events",
    "sales_state_transitions",
    "sales_ticket_issues",
    "sales_ticket_offers",
    "sales_ticket_resend_challenges"
  ]

  test "creates the expected Sales table inventory through VS-01E" do
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

  test "conversation table and optional order link expose required columns" do
    assert_columns("sales_conversations", [
      "id",
      "phone_e164",
      "wa_id",
      "session_key",
      "rate_limit_key",
      "preferred_language",
      "locale",
      "state",
      "state_data",
      "last_inbound_message_id",
      "last_outbound_message_id",
      "last_message_at",
      "expires_at",
      "needs_human",
      "handoff_reason",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_orders", ["sales_conversation_id"])
  end

  test "conversation checkpoint fields use expected column types" do
    assert_column_type("sales_conversations", "state_data", "jsonb")
    assert_column_type("sales_conversations", "needs_human", "boolean")
    assert_column_type("sales_conversations", "last_message_at", "timestamp without time zone")
    assert_column_type("sales_conversations", "expires_at", "timestamp without time zone")
  end

  test "required conversation indexes exist" do
    assert_index("sales_conversations_phone_e164_idx")
    assert_index("sales_conversations_wa_id_idx")
    assert_index("sales_conversations_session_key_idx")
    assert_index("sales_conversations_needs_human_last_message_at_idx")
    assert_index("sales_conversations_state_expires_at_idx")
    assert_index("sales_conversations_last_message_at_idx")
    assert_index("sales_orders_sales_conversation_id_idx")
  end

  test "orders may optionally link to conversations with a restrict foreign key" do
    assert_foreign_key("sales_orders", "sales_conversation_id", "sales_conversations")
    assert_foreign_key_delete_rule("sales_orders", "sales_conversation_id", "RESTRICT")
  end

  test "database constraints reject unsafe conversation skeleton data" do
    assert_db_error(~r/sales_conversations_phone_e164_format/, fn ->
      insert_conversation!(phone_e164: "27821234567")
    end)

    assert_db_error(~r/sales_conversations_state_valid/, fn ->
      insert_conversation!(state: "not_a_state")
    end)

    assert_db_error(~r/sales_conversations_preferred_language_valid/, fn ->
      insert_conversation!(preferred_language: "zz")
    end)
  end

  test "phone lookup is not globally unique and orders remain valid without conversations" do
    insert_conversation!()
    insert_conversation!(phone_e164: "+27821234567", wa_id: "wa-2")

    order_id = insert_order!()

    assert [[^order_id, nil]] =
             Repo.query!(
               """
               SELECT id, sales_conversation_id
               FROM sales_orders
               WHERE id = $1
               """,
               [order_id]
             ).rows
  end

  defp insert_conversation!(opts \\ []) do
    phone_e164 = Keyword.get(opts, :phone_e164, "+27821234567")
    wa_id = Keyword.get(opts, :wa_id, "wa-#{System.unique_integer([:positive])}")
    preferred_language = Keyword.get(opts, :preferred_language, "af")
    state = Keyword.get(opts, :state, "new")

    Repo.query!(
      """
      INSERT INTO sales_conversations
        (phone_e164, wa_id, preferred_language, state, state_data, needs_human, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, '{}', false, now(), now())
      """,
      [phone_e164, wa_id, preferred_language, state]
    )
  end

  defp insert_order! do
    result =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, source_channel, status, total_amount_cents,
           currency, inserted_at, updated_at)
        VALUES
          ($1, 1, 'Buyer', 'whatsapp', 'draft', 100, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}"]
      )

    [[id]] = result.rows
    id
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
           "#{table_name} must not include organization_id in VS-01E"
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

  defp assert_foreign_key_delete_rule(table_name, column_name, delete_rule) do
    assert [[^delete_rule]] =
             Repo.query!(
               """
               SELECT rc.delete_rule
               FROM information_schema.referential_constraints rc
               JOIN information_schema.key_column_usage kcu
                 ON rc.constraint_name = kcu.constraint_name
               WHERE kcu.table_name = $1
                 AND kcu.column_name = $2
               """,
               [table_name, column_name]
             ).rows
  end

  defp assert_db_error(pattern, fun) do
    assert_raise Postgrex.Error, pattern, fun
  end
end
