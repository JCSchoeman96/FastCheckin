defmodule FastCheck.Sales.Vs01gIndexAndMigrationVerificationTest do
  use FastCheck.DataCase, async: true

  @sales_tables [
    "sales_checkout_sessions",
    "sales_conversations",
    "sales_delivery_attempts",
    "sales_order_lines",
    "sales_orders",
    "sales_payment_attempts",
    "sales_payment_events",
    "sales_state_transitions",
    "sales_ticket_issues",
    "sales_ticket_offers"
  ]

  @resources [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.StateTransition,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt,
    FastCheck.Sales.Conversation
  ]

  @forbidden_paths [
    "lib/fastcheck/messaging/whatsapp",
    "lib/fastcheck/tickets/issuer.ex",
    "lib/fastcheck/tickets/code_generator.ex",
    "lib/fastcheck/tickets/qr_payload.ex",
    "lib/fastcheck/tickets/delivery_token.ex",
    "lib/fastcheck/workers",
    "lib/fastcheck_web/controllers/ticket_delivery_controller.ex"
  ]

  @allowed_actions_by_resource %{
    FastCheck.Sales.PaymentEvent => [
      :store_webhook_event,
      :mark_processing_started,
      :mark_processed,
      :mark_unmatched,
      :mark_failed
    ],
    FastCheck.Sales.PaymentAttempt => [
      :mark_verification_started,
      :mark_verified_success,
      :mark_verified_amount_mismatch,
      :mark_verified_currency_mismatch,
      :mark_verification_failed,
      :get_by_provider_reference
    ],
    FastCheck.Sales.Order => [:mark_paid_verified],
    FastCheck.Sales.CheckoutSession => [:mark_paid]
  }

  @forbidden_action_names [
    :create,
    :update,
    :destroy,
    :upsert,
    :update_status,
    :update_state,
    :store_webhook_event,
    :mark_verified_success,
    :issue_ticket,
    :revoke_ticket,
    :send_whatsapp,
    :start_or_resume,
    :confirm_order
  ]

  test "keeps the complete VS-01G Sales table inventory present and tenant-free" do
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

    for table <- @sales_tables do
      refute column_exists?(table, "organization_id"),
             "#{table} must not include organization_id in VS-01G"
    end
  end

  test "required query-path indexes and partial unique indexes match the VS-01G contract" do
    assert_index("sales_ticket_offers_active_name_uidx", ["event_id", "name"],
      unique?: true,
      where: "archived_at IS NULL"
    )

    assert_index("sales_ticket_offers_event_sales_window_idx", [
      "event_id",
      "sales_enabled",
      "starts_at",
      "ends_at"
    ])

    assert_index("sales_orders_public_reference_uidx", ["public_reference"], unique?: true)

    assert_index("sales_orders_idempotency_key_uidx", ["idempotency_key"],
      unique?: true,
      where: "idempotency_key IS NOT NULL"
    )

    assert_index("sales_orders_event_status_inserted_at_idx", [
      "event_id",
      "status",
      "inserted_at"
    ])

    assert_index("sales_orders_event_source_inserted_at_idx", [
      "event_id",
      "source_channel",
      "inserted_at"
    ])

    assert_index("sales_orders_buyer_phone_idx", ["buyer_phone"])
    assert_index("sales_orders_expires_status_idx", ["expires_at", "status"])

    assert_index("sales_orders_status_fulfillment_queued_at_idx", [
      "status",
      "fulfillment_queued_at"
    ])

    assert_index("sales_orders_sales_conversation_id_idx", ["sales_conversation_id"])

    assert_index("sales_order_lines_sales_order_id_idx", ["sales_order_id"])
    assert_index("sales_order_lines_ticket_offer_id_idx", ["ticket_offer_id"])

    assert_index("sales_order_lines_order_line_number_uidx", ["sales_order_id", "line_number"],
      unique?: true
    )

    assert_index("sales_checkout_sessions_sales_order_id_uidx", ["sales_order_id"], unique?: true)

    assert_index("sales_checkout_sessions_redis_hold_key_uidx", ["redis_hold_key"],
      unique?: true,
      where: "redis_hold_key IS NOT NULL"
    )

    assert_index("sales_checkout_sessions_status_expires_at_idx", ["status", "expires_at"])

    assert_index("sales_checkout_sessions_sales_order_id_status_idx", ["sales_order_id", "status"])

    assert_index(
      "sales_payment_attempts_provider_reference_uidx",
      [
        "provider",
        "provider_reference"
      ],
      unique?: true
    )

    assert_index("sales_payment_attempts_sales_order_id_status_idx", ["sales_order_id", "status"])
    assert_index("sales_payment_attempts_provider_status_idx", ["provider", "status"])
    assert_index("sales_payment_attempts_last_verified_at_idx", ["last_verified_at"])

    assert_index(
      "sales_payment_events_provider_event_id_uidx",
      [
        "provider",
        "provider_event_id"
      ],
      unique?: true,
      where: "provider_event_id IS NOT NULL"
    )

    assert_index("sales_payment_events_provider_payload_hash_uidx", ["provider", "payload_hash"],
      unique?: true,
      where: "provider_event_id IS NULL"
    )

    assert_index("sales_payment_events_provider_reference_idx", ["provider_reference"])

    assert_index("sales_payment_events_processing_status_inserted_at_idx", [
      "processing_status",
      "inserted_at"
    ])

    assert_index("sales_ticket_issues_ticket_code_uidx", ["ticket_code"],
      unique?: true,
      where: "ticket_code IS NOT NULL"
    )

    assert_index(
      "sales_ticket_issues_order_line_sequence_uidx",
      [
        "sales_order_line_id",
        "line_item_sequence"
      ],
      unique?: true
    )

    assert_index("sales_ticket_issues_attendee_id_uidx", ["attendee_id"],
      unique?: true,
      where: "attendee_id IS NOT NULL"
    )

    assert_index("sales_ticket_issues_sales_order_id_idx", ["sales_order_id"])
    assert_index("sales_ticket_issues_sales_order_line_id_idx", ["sales_order_line_id"])
    assert_index("sales_ticket_issues_status_idx", ["status"])
    assert_index("sales_ticket_issues_scanner_status_idx", ["scanner_status"])

    assert_index("sales_delivery_attempts_sales_order_id_status_idx", ["sales_order_id", "status"])

    assert_index("sales_delivery_attempts_ticket_issue_id_status_idx", [
      "ticket_issue_id",
      "status"
    ])

    assert_index("sales_delivery_attempts_provider_message_id_idx", ["provider_message_id"])

    assert_index("sales_delivery_attempts_channel_status_inserted_at_idx", [
      "channel",
      "status",
      "inserted_at"
    ])

    assert_index("sales_conversations_phone_e164_idx", ["phone_e164"])
    assert_index("sales_conversations_wa_id_idx", ["wa_id"])
    assert_index("sales_conversations_session_key_idx", ["session_key"])

    assert_index("sales_conversations_needs_human_last_message_at_idx", [
      "needs_human",
      "last_message_at"
    ])

    assert_index("sales_conversations_state_expires_at_idx", ["state", "expires_at"])

    assert_index("sales_state_transitions_entity_idx", ["entity_type", "entity_id", "inserted_at"])

    assert_index("sales_state_transitions_actor_idx", ["actor_type", "actor_id", "inserted_at"])
    assert_index("sales_state_transitions_correlation_id_idx", ["correlation_id"])
  end

  test "relationship paths use foreign keys where the accepted contract requires them" do
    assert_foreign_key("sales_order_lines", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_order_lines", "ticket_offer_id", "sales_ticket_offers")
    assert_foreign_key("sales_checkout_sessions", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_payment_attempts", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_ticket_issues", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_ticket_issues", "sales_order_line_id", "sales_order_lines")
    assert_foreign_key("sales_delivery_attempts", "sales_order_id", "sales_orders")
    assert_foreign_key("sales_delivery_attempts", "ticket_issue_id", "sales_ticket_issues")
    assert_foreign_key("sales_orders", "sales_conversation_id", "sales_conversations")
  end

  test "Ash identities align with critical DB unique indexes" do
    assert_identity(
      FastCheck.Sales.TicketOffer,
      :unique_active_name_per_event,
      [:event_id, :name],
      index_name: "sales_ticket_offers_active_name_uidx"
    )

    assert_identity(FastCheck.Sales.Order, :unique_public_reference, [:public_reference],
      index_name: "sales_orders_public_reference_uidx"
    )

    assert_identity(FastCheck.Sales.Order, :unique_idempotency_key, [:idempotency_key],
      index_name: "sales_orders_idempotency_key_uidx"
    )

    assert_identity(
      FastCheck.Sales.OrderLine,
      :unique_line_number_per_order,
      [
        :sales_order_id,
        :line_number
      ],
      index_name: "sales_order_lines_order_line_number_uidx"
    )

    assert_identity(FastCheck.Sales.CheckoutSession, :unique_order, [:sales_order_id],
      index_name: "sales_checkout_sessions_sales_order_id_uidx"
    )

    assert_identity(FastCheck.Sales.CheckoutSession, :unique_redis_hold_key, [:redis_hold_key],
      index_name: "sales_checkout_sessions_redis_hold_key_uidx"
    )

    assert_identity(
      FastCheck.Sales.PaymentAttempt,
      :unique_provider_reference,
      [
        :provider,
        :provider_reference
      ],
      index_name: "sales_payment_attempts_provider_reference_uidx"
    )

    assert_identity(
      FastCheck.Sales.PaymentEvent,
      :unique_provider_event_id,
      [
        :provider,
        :provider_event_id
      ],
      index_name: "sales_payment_events_provider_event_id_uidx"
    )

    assert_identity(
      FastCheck.Sales.PaymentEvent,
      :unique_provider_payload_hash,
      [
        :provider,
        :payload_hash
      ],
      index_name: "sales_payment_events_provider_payload_hash_uidx"
    )

    assert_identity(FastCheck.Sales.TicketIssue, :unique_ticket_code, [:ticket_code],
      index_name: "sales_ticket_issues_ticket_code_uidx"
    )

    assert_identity(
      FastCheck.Sales.TicketIssue,
      :unique_line_item_sequence,
      [
        :sales_order_line_id,
        :line_item_sequence
      ],
      index_name: "sales_ticket_issues_order_line_sequence_uidx"
    )

    assert_identity(FastCheck.Sales.TicketIssue, :unique_attendee_id, [:attendee_id],
      index_name: "sales_ticket_issues_attendee_id_uidx"
    )
  end

  test "critical DB-level idempotency and uniqueness constraints reject duplicates" do
    offer_id = insert_ticket_offer!(event_id: 101, name: "VS-01G GA")

    assert_db_error(~r/sales_ticket_offers_active_name_uidx/, fn ->
      insert_ticket_offer!(event_id: 101, name: "VS-01G GA")
    end)

    insert_ticket_offer!(event_id: 101, name: "VS-01G GA", archived?: true)

    order_id =
      insert_order!(
        public_reference: "FC-VS01G-ORDER",
        idempotency_key: "idem-vs01g-1"
      )

    assert_db_error(~r/sales_orders_public_reference_uidx/, fn ->
      insert_order!(public_reference: "FC-VS01G-ORDER")
    end)

    assert_db_error(~r/sales_orders_idempotency_key_uidx/, fn ->
      insert_order!(idempotency_key: "idem-vs01g-1")
    end)

    insert_order!(idempotency_key: nil)
    insert_order!(idempotency_key: nil)

    order_line_id = insert_order_line!(order_id, offer_id, line_number: 1)

    assert_db_error(~r/sales_order_lines_order_line_number_uidx/, fn ->
      insert_order_line!(order_id, offer_id, line_number: 1)
    end)

    insert_checkout_session!(order_id, redis_hold_key: "hold-vs01g-1")

    assert_db_error(~r/sales_checkout_sessions_sales_order_id_uidx/, fn ->
      insert_checkout_session!(order_id)
    end)

    another_order_id = insert_order!()

    assert_db_error(~r/sales_checkout_sessions_redis_hold_key_uidx/, fn ->
      insert_checkout_session!(another_order_id, redis_hold_key: "hold-vs01g-1")
    end)

    insert_payment_attempt!(order_id, provider_reference: "pay-vs01g-1")

    assert_db_error(~r/sales_payment_attempts_provider_reference_uidx/, fn ->
      insert_payment_attempt!(order_id, provider_reference: "pay-vs01g-1")
    end)

    insert_payment_event!(provider_event_id: "evt-vs01g-1", payload_hash: "hash-vs01g-1")

    assert_db_error(~r/sales_payment_events_provider_event_id_uidx/, fn ->
      insert_payment_event!(provider_event_id: "evt-vs01g-1", payload_hash: "hash-vs01g-2")
    end)

    insert_payment_event!(provider_event_id: nil, payload_hash: "hash-vs01g-null")

    assert_db_error(~r/sales_payment_events_provider_payload_hash_uidx/, fn ->
      insert_payment_event!(provider_event_id: nil, payload_hash: "hash-vs01g-null")
    end)

    insert_ticket_issue!(order_id, order_line_id,
      line_item_sequence: 1,
      ticket_code: "TICKET-VS01G-1"
    )

    assert_db_error(~r/sales_ticket_issues_order_line_sequence_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id, line_item_sequence: 1)
    end)

    assert_db_error(~r/sales_ticket_issues_ticket_code_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id,
        line_item_sequence: 2,
        ticket_code: "TICKET-VS01G-1"
      )
    end)

    insert_ticket_issue!(order_id, order_line_id, line_item_sequence: 2, attendee_id: 90_001)

    assert_db_error(~r/sales_ticket_issues_attendee_id_uidx/, fn ->
      insert_ticket_issue!(order_id, order_line_id, line_item_sequence: 3, attendee_id: 90_001)
    end)
  end

  test "VS-01G does not introduce tenant fields, workflow actions, or forbidden runtime paths" do
    for resource <- @resources do
      refute Ash.Resource.Info.attribute(resource, :organization_id),
             "#{inspect(resource)} must not define organization_id in VS-01G"

      for action_name <- @forbidden_action_names,
          action_name not in Map.get(@allowed_actions_by_resource, resource, []) do
        refute Ash.Resource.Info.action(resource, action_name),
               "#{inspect(resource)} must not expose #{inspect(action_name)} in VS-01G"
      end
    end

    for path <- @forbidden_paths do
      refute File.exists?(path), "#{path} is out of scope for VS-01G"
    end
  end

  defp assert_index(index_name, expected_columns, opts \\ []) do
    unique? = Keyword.get(opts, :unique?, false)
    expected_where = Keyword.get(opts, :where)

    assert [[^index_name, ^unique?, columns, where_clause]] =
             Repo.query!(
               """
               SELECT
                 i.relname,
                 ix.indisunique,
                 array_agg(a.attname ORDER BY ord.ordinality),
                 pg_get_expr(ix.indpred, ix.indrelid)
               FROM pg_class t
               JOIN pg_index ix ON t.oid = ix.indrelid
               JOIN pg_class i ON i.oid = ix.indexrelid
               JOIN unnest(ix.indkey) WITH ORDINALITY AS ord(attnum, ordinality) ON true
               JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ord.attnum
               JOIN pg_namespace n ON n.oid = t.relnamespace
               WHERE n.nspname = 'public'
                 AND i.relname = $1
               GROUP BY i.relname, ix.indisunique, ix.indpred, ix.indrelid
               """,
               [index_name]
             ).rows

    assert columns == expected_columns,
           "#{index_name} must index #{inspect(expected_columns)}, got #{inspect(columns)}"

    if expected_where do
      assert where_clause =~ expected_where,
             "#{index_name} must use predicate #{expected_where}, got #{inspect(where_clause)}"
    end
  end

  defp assert_identity(resource, identity_name, expected_keys, opts) do
    identity = Enum.find(Ash.Resource.Info.identities(resource), &(&1.name == identity_name))
    assert identity, "#{inspect(resource)} is missing identity #{identity_name}"
    assert identity.keys == expected_keys

    index_name = Keyword.fetch!(opts, :index_name)
    identity_index_names = AshPostgres.DataLayer.Info.identity_index_names(resource)
    assert identity_index_names[identity_name] == index_name
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

  defp column_exists?(table_name, column_name) do
    Repo.query!(
      """
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = $1
        AND column_name = $2
      """,
      [table_name, column_name]
    ).rows != []
  end

  defp insert_ticket_offer!(opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    name = Keyword.fetch!(opts, :name)
    archived_at = if Keyword.get(opts, :archived?, false), do: "now()", else: "NULL"

    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, archived_at, inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', 100, 'ZAR', 10, 10, 5, true, 'whatsapp',
           now(), now() + interval '1 day', 1, #{archived_at}, now(), now())
        RETURNING id
        """,
        [event_id, name]
      )

    [[id]] = result.rows
    id
  end

  defp insert_order!(opts \\ []) do
    public_reference =
      Keyword.get(opts, :public_reference, "FC-VS01G-#{System.unique_integer([:positive])}")

    idempotency_key =
      Keyword.get(opts, :idempotency_key, "idem-#{System.unique_integer([:positive])}")

    result =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, source_channel, status,
           total_amount_cents, currency, idempotency_key, inserted_at, updated_at)
        VALUES
          ($1, 1, 'Synthetic Buyer', '+27820000000', 'whatsapp', 'draft', 100, 'ZAR',
           $2, now(), now())
        RETURNING id
        """,
        [public_reference, idempotency_key]
      )

    [[id]] = result.rows
    id
  end

  defp insert_order_line!(order_id, offer_id, opts) do
    line_number = Keyword.fetch!(opts, :line_number)

    result =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, $3, 'general', 'VS-01G Offer', 'VS-01G Event', 1, 100, 100, 'ZAR',
           '{}', now(), now())
        RETURNING id
        """,
        [order_id, offer_id, line_number]
      )

    [[id]] = result.rows
    id
  end

  defp insert_checkout_session!(order_id, opts \\ []) do
    redis_hold_key = Keyword.get(opts, :redis_hold_key)

    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_quantity, state_data, lock_version,
         inserted_at, updated_at)
      VALUES
        ($1, 'created', $2, 1, '{}', 1, now(), now())
      """,
      [order_id, redis_hold_key]
    )
  end

  defp insert_payment_attempt!(order_id, opts) do
    provider_reference = Keyword.fetch!(opts, :provider_reference)

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, status, amount_cents, currency,
         verification_attempt_count, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, 'initialized', 100, 'ZAR', 0, now(), now())
      """,
      [order_id, provider_reference]
    )
  end

  defp insert_payment_event!(opts) do
    provider_event_id = Keyword.fetch!(opts, :provider_event_id)
    payload_hash = Keyword.fetch!(opts, :payload_hash)

    Repo.query!(
      """
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, payload_hash, raw_payload,
         processing_status, processing_attempt_count, inserted_at, updated_at)
      VALUES
        ('paystack', $1, 'pay-vs01g', 'charge.success', $2, '{}', 'stored', 0, now(), now())
      """,
      [provider_event_id, payload_hash]
    )
  end

  defp insert_ticket_issue!(order_id, order_line_id, opts) do
    line_item_sequence = Keyword.fetch!(opts, :line_item_sequence)
    ticket_code = Keyword.get(opts, :ticket_code)
    attendee_id = Keyword.get(opts, :attendee_id)

    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         status, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, $4, $5, 'pending', now(), now())
      """,
      [order_id, order_line_id, line_item_sequence, attendee_id, ticket_code]
    )
  end

  defp assert_db_error(pattern, fun) do
    assert_raise Postgrex.Error, pattern, fun
  end
end
