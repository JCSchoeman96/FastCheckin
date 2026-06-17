defmodule FastCheck.Sales.CheckoutAndPaymentResourceMigrationsTest do
  use FastCheck.DataCase, async: true

  @sales_tables [
    "sales_checkout_sessions",
    "sales_order_lines",
    "sales_orders",
    "sales_payment_attempts",
    "sales_payment_events",
    "sales_state_transitions",
    "sales_ticket_offers"
  ]

  test "keeps the VS-01C checkout and payment tables present" do
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
      assert table in existing_tables, "VS-01C table #{table} must remain present"
    end
  end

  test "checkout and payment tables expose required columns" do
    assert_columns("sales_checkout_sessions", [
      "id",
      "sales_order_id",
      "status",
      "redis_hold_key",
      "hold_token",
      "hold_quantity",
      "payment_link_sent_at",
      "released_at",
      "expired_at",
      "last_seen_at",
      "expires_at",
      "state_data",
      "lock_version",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_payment_attempts", [
      "id",
      "sales_order_id",
      "provider",
      "provider_reference",
      "idempotency_key",
      "authorization_url",
      "access_code",
      "status",
      "provider_status",
      "amount_cents",
      "currency",
      "initialized_at",
      "provider_paid_at",
      "verified_at",
      "last_verified_at",
      "verification_attempt_count",
      "failure_code",
      "failure_message",
      "manual_review_reason",
      "raw_initialize_response",
      "raw_verify_response",
      "inserted_at",
      "updated_at"
    ])

    assert_columns("sales_payment_events", [
      "id",
      "provider",
      "provider_event_id",
      "provider_reference",
      "event_type",
      "signature_valid",
      "payload_hash",
      "raw_payload",
      "received_at",
      "processed_at",
      "processing_status",
      "processing_attempt_count",
      "last_processing_error",
      "last_processing_error_at",
      "inserted_at",
      "updated_at"
    ])
  end

  test "money and quantity fields use integer columns" do
    assert_column_type("sales_checkout_sessions", "hold_quantity", "integer")
    assert_column_type("sales_payment_attempts", "amount_cents", "integer")
    assert_column_type("sales_payment_attempts", "verification_attempt_count", "integer")
    assert_column_type("sales_payment_events", "processing_attempt_count", "integer")
  end

  test "required indexes and partial unique indexes exist" do
    assert_index("sales_checkout_sessions_sales_order_id_uidx")
    assert_index("sales_checkout_sessions_redis_hold_key_uidx")
    assert_index("sales_checkout_sessions_status_expires_at_idx")
    assert_index("sales_checkout_sessions_sales_order_id_status_idx")
    assert_index("sales_payment_attempts_provider_reference_uidx")
    assert_index("sales_payment_attempts_sales_order_id_status_idx")
    assert_index("sales_payment_attempts_provider_status_idx")
    assert_index("sales_payment_attempts_last_verified_at_idx")
    assert_index("sales_payment_attempts_idempotency_key_active_uidx")
    assert_index("sales_payment_events_provider_event_id_uidx")
    assert_index("sales_payment_events_provider_payload_hash_uidx")
    assert_index("sales_payment_events_provider_reference_idx")
    assert_index("sales_payment_events_processing_status_inserted_at_idx")

    assert_index_where(
      "sales_checkout_sessions_redis_hold_key_uidx",
      "redis_hold_key IS NOT NULL"
    )

    assert_index_where(
      "sales_payment_events_provider_event_id_uidx",
      "provider_event_id IS NOT NULL"
    )

    assert_index_where(
      "sales_payment_events_provider_payload_hash_uidx",
      "provider_event_id IS NULL"
    )

    assert_index_where(
      "sales_payment_attempts_idempotency_key_active_uidx",
      "idempotency_key IS NOT NULL"
    )
  end

  test "initializing status and active idempotency index allow failed retry slot" do
    order_id = insert_order!()
    key = "paystack:init:#{order_id}:99"

    insert_payment_attempt!(order_id, "initializing",
      idempotency_key: key,
      provider_reference: "FC-active-1"
    )

    assert_db_error(~r/sales_payment_attempts_idempotency_key_active_uidx/, fn ->
      insert_payment_attempt!(order_id, "initialized",
        idempotency_key: key,
        provider_reference: "FC-active-2"
      )
    end)

    FastCheck.Repo.query!(
      """
      UPDATE sales_payment_attempts
      SET status = 'failed'
      WHERE sales_order_id = $1 AND idempotency_key = $2
      """,
      [order_id, key]
    )

    insert_payment_attempt!(order_id, "initializing",
      idempotency_key: key,
      provider_reference: "FC-retry-#{System.unique_integer([:positive])}"
    )
  end

  test "payment attempt status constraint accepts initializing" do
    order_id = insert_order!()
    insert_payment_attempt!(order_id, "initializing")
  end

  test "checkout and payment tables enforce foreign keys" do
    assert_foreign_key("sales_checkout_sessions", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_payment_attempts", "sales_order_id", "sales_orders")
  end

  test "database constraints reject unsafe checkout and payment skeleton data" do
    order_id = insert_order!()

    assert_db_error(~r/sales_checkout_sessions_status_valid/, fn ->
      insert_checkout_session!(order_id, "not_a_state")
    end)

    assert_db_error(~r/sales_checkout_sessions_hold_quantity_non_negative/, fn ->
      insert_checkout_session!(order_id, "created", hold_quantity: -1)
    end)

    assert_db_error(~r/sales_payment_attempts_status_valid/, fn ->
      insert_payment_attempt!(order_id, "not_a_state")
    end)

    assert_db_error(~r/sales_payment_attempts_amount_cents_non_negative/, fn ->
      insert_payment_attempt!(order_id, "initialized", amount_cents: -1)
    end)

    assert_db_error(~r/sales_payment_attempts_currency_format/, fn ->
      insert_payment_attempt!(order_id, "initialized", currency: "zar")
    end)

    assert_db_error(~r/sales_payment_events_processing_status_valid/, fn ->
      insert_payment_event!("not_a_state")
    end)

    assert_db_error(~r/sales_payment_events_dedupe_identity_present/, fn ->
      insert_payment_event!("stored", provider_event_id: nil, payload_hash: nil)
    end)

    insert_checkout_session!(order_id, "created")

    assert_db_error(~r/sales_checkout_sessions_sales_order_id_uidx/, fn ->
      insert_checkout_session!(order_id, "created")
    end)
  end

  test "partial unique webhook dedupe indexes reject duplicates" do
    insert_payment_event!("stored", provider_event_id: "evt-1", payload_hash: "hash-1")

    assert_db_error(~r/sales_payment_events_provider_event_id_uidx/, fn ->
      insert_payment_event!("stored", provider_event_id: "evt-1", payload_hash: "hash-2")
    end)

    insert_payment_event!("stored", provider_event_id: nil, payload_hash: "hash-null-1")

    assert_db_error(~r/sales_payment_events_provider_payload_hash_uidx/, fn ->
      insert_payment_event!("stored", provider_event_id: nil, payload_hash: "hash-null-1")
    end)
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

  defp insert_checkout_session!(order_id, status, opts \\ []) do
    hold_quantity = Keyword.get(opts, :hold_quantity, 1)

    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, '{}', 1, now(), now())
      """,
      [order_id, status, hold_quantity]
    )
  end

  defp insert_payment_attempt!(order_id, status, opts \\ []) do
    amount_cents = Keyword.get(opts, :amount_cents, 100)
    currency = Keyword.get(opts, :currency, "ZAR")

    reference =
      Keyword.get(opts, :provider_reference, "ref-#{System.unique_integer([:positive])}")

    idempotency_key = Keyword.get(opts, :idempotency_key)

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, status, amount_cents, currency,
         verification_attempt_count, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, $3, $4, $5, $6, 0, now(), now())
      """,
      [order_id, reference, idempotency_key, status, amount_cents, currency]
    )
  end

  defp insert_payment_event!(processing_status, opts \\ []) do
    provider_event_id =
      Keyword.get(opts, :provider_event_id, "evt-#{System.unique_integer([:positive])}")

    payload_hash = Keyword.get(opts, :payload_hash, "hash-#{System.unique_integer([:positive])}")

    Repo.query!(
      """
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, payload_hash, raw_payload,
         processing_status, processing_attempt_count, inserted_at, updated_at)
      VALUES
        ('paystack', $1, 'ref-1', 'charge.success', $2, '{}', $3, 0, now(), now())
      """,
      [provider_event_id, payload_hash, processing_status]
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
           "#{table_name} must not include organization_id in VS-01C"
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
