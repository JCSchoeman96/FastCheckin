defmodule FastCheck.Sales.TicketAndDeliveryResourceMigrationsTest do
  use FastCheck.DataCase, async: true

  @sales_tables [
    "sales_checkout_sessions",
    "sales_delivery_attempts",
    "sales_order_lines",
    "sales_orders",
    "sales_payment_attempts",
    "sales_payment_events",
    "sales_state_transitions",
    "sales_ticket_issues",
    "sales_ticket_offers"
  ]

  test "keeps the VS-01D ticket and delivery tables present" do
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
      |> MapSet.new()

    for table <- @sales_tables do
      assert table in existing_tables, "VS-01D table #{table} must remain present"
    end
  end

  test "ticket and delivery tables expose required columns" do
    assert_columns("sales_ticket_issues", [
      "id",
      "sales_order_id",
      "sales_order_line_id",
      "line_item_sequence",
      "attendee_id",
      "ticket_code",
      "qr_token_hash",
      "delivery_token_hash",
      "delivery_token_expires_at",
      "status",
      "scanner_status",
      "last_scanner_sync_version",
      "issued_at",
      "revoked_at",
      "revocation_reason",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_delivery_attempts", [
      "id",
      "sales_order_id",
      "ticket_issue_id",
      "channel",
      "provider",
      "recipient",
      "status",
      "template_name",
      "within_whatsapp_window",
      "provider_message_id",
      "attempt_number",
      "provider_error_code",
      "provider_error_message",
      "failure_reason",
      "fallback_channel",
      "correlation_id",
      "sent_at",
      "delivered_at",
      "inserted_at",
      "updated_at"
    ])
  end

  test "sequence fields use integer columns" do
    assert_column_type("sales_ticket_issues", "line_item_sequence", "integer")
    assert_column_type("sales_ticket_issues", "last_scanner_sync_version", "integer")
    assert_column_type("sales_delivery_attempts", "attempt_number", "integer")
  end

  test "required indexes and partial unique indexes exist" do
    assert_index("sales_ticket_issues_ticket_code_uidx")
    assert_index("sales_ticket_issues_order_line_sequence_uidx")
    assert_index("sales_ticket_issues_attendee_id_uidx")
    assert_index("sales_ticket_issues_sales_order_id_idx")
    assert_index("sales_ticket_issues_sales_order_line_id_idx")
    assert_index("sales_ticket_issues_status_idx")
    assert_index("sales_ticket_issues_scanner_status_idx")
    assert_index("sales_delivery_attempts_sales_order_id_status_idx")
    assert_index("sales_delivery_attempts_ticket_issue_id_status_idx")
    assert_index("sales_delivery_attempts_provider_message_id_idx")
    assert_index("sales_delivery_attempts_channel_status_inserted_at_idx")
    assert_index("sales_delivery_attempts_correlation_id_idx")

    assert_index_where("sales_ticket_issues_ticket_code_uidx", "ticket_code IS NOT NULL")
    assert_index_where("sales_ticket_issues_attendee_id_uidx", "attendee_id IS NOT NULL")
  end

  test "ticket and delivery tables enforce foreign keys" do
    assert_foreign_key("sales_ticket_issues", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_ticket_issues", "sales_order_line_id", "sales_order_lines")
    assert_foreign_key("sales_delivery_attempts", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_delivery_attempts", "ticket_issue_id", "sales_ticket_issues")
  end

  test "database constraints reject unsafe ticket and delivery skeleton data" do
    {order_id, order_line_id} = insert_order_with_line!()

    assert_db_error(~r/sales_ticket_issues_status_valid/, fn ->
      insert_ticket_issue!(order_id, order_line_id, "delivered")
    end)

    assert_db_error(~r/sales_ticket_issues_line_item_sequence_positive/, fn ->
      insert_ticket_issue!(order_id, order_line_id, "pending", line_item_sequence: 0)
    end)

    ticket_issue_id = insert_ticket_issue!(order_id, order_line_id, "pending")

    assert_db_error(~r/sales_delivery_attempts_status_valid/, fn ->
      insert_delivery_attempt!(order_id, ticket_issue_id, "whatsapp", "not_a_state")
    end)

    assert_db_error(~r/sales_delivery_attempts_channel_valid/, fn ->
      insert_delivery_attempt!(order_id, ticket_issue_id, "sms", "queued")
    end)

    assert_db_error(~r/sales_delivery_attempts_attempt_number_positive/, fn ->
      insert_delivery_attempt!(order_id, ticket_issue_id, "whatsapp", "queued", attempt_number: 0)
    end)
  end

  test "partial unique indexes reject duplicate ticket issue identities" do
    {order_id, order_line_id} = insert_order_with_line!()

    insert_ticket_issue!(order_id, order_line_id, "pending",
      line_item_sequence: 1,
      ticket_code: "TICKET-1"
    )

    assert_db_error(~r/sales_ticket_issues_order_line_sequence_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id, "pending", line_item_sequence: 1)
    end)

    assert_db_error(~r/sales_ticket_issues_ticket_code_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id, "pending",
        line_item_sequence: 2,
        ticket_code: "TICKET-1"
      )
    end)

    insert_ticket_issue!(order_id, order_line_id, "pending",
      line_item_sequence: 2,
      attendee_id: 42
    )

    assert_db_error(~r/sales_ticket_issues_attendee_id_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id, "pending",
        line_item_sequence: 3,
        attendee_id: 42
      )
    end)
  end

  defp insert_order_with_line! do
    offer_id = insert_ticket_offer!()
    order_id = insert_order!()

    result =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'Offer', 'Event', 1, 100, 100, 'ZAR', '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id]
      )

    [[order_line_id]] = result.rows
    {order_id, order_line_id}
  end

  defp insert_ticket_offer! do
    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          (1, 'GA', 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp', now(), now() + interval '1 day',
           1, now(), now())
        RETURNING id
        """,
        []
      )

    [[id]] = result.rows
    id
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

  defp insert_ticket_issue!(order_id, order_line_id, status, opts \\ []) do
    line_item_sequence = Keyword.get(opts, :line_item_sequence, 1)
    ticket_code = Keyword.get(opts, :ticket_code)
    attendee_id = Keyword.get(opts, :attendee_id)

    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           status, inserted_at, updated_at)
        VALUES
          ($1, $2, $3, $4, $5, $6, now(), now())
        RETURNING id
        """,
        [order_id, order_line_id, line_item_sequence, attendee_id, ticket_code, status]
      )

    [[id]] = result.rows
    id
  end

  defp insert_delivery_attempt!(order_id, ticket_issue_id, channel, status, opts \\ []) do
    attempt_number = Keyword.get(opts, :attempt_number, 1)

    Repo.query!(
      """
      INSERT INTO sales_delivery_attempts
        (sales_order_id, ticket_issue_id, channel, status, attempt_number, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, now(), now())
      """,
      [order_id, ticket_issue_id, channel, status, attempt_number]
    )
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
           "#{table_name} must not include organization_id in VS-01D"
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
