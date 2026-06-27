defmodule FastCheck.Sales.AuditViewsTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Repo
  alias FastCheck.Sales.AuditViews

  @raw_email "audit.raw@example.com"
  @raw_phone "+27987654321"
  @authorization_url "https://checkout.paystack.test/pay/audit-secret"
  @access_code "AUDIT_ACCESS_SECRET"
  @ticket_code "AUDIT-TICKET-SECRET"
  @qr_hash "audit-qr-hash"
  @delivery_hash "audit-delivery-hash"
  @idempotency_key "audit-idempotency-secret"
  @raw_processing_error "provider said card holder audit.raw@example.com failed with token secret"

  test "timeline rejects unknown entity types and invalid ids" do
    assert {:error, :invalid_entity_type} = AuditViews.timeline("unknown", "123")
    assert {:error, :invalid_entity_id} = AuditViews.timeline("order", "not-an-id")
  end

  test "order timeline is newest first, paginated, and redacted" do
    order_id = insert_order!()

    insert_transition!("Order", order_id, "draft", "manual_review", seconds_ago: 60)
    insert_transition!("Order", order_id, "manual_review", "refunded", seconds_ago: 5)
    insert_payment_attempt!(order_id)

    assert {:ok, page} = AuditViews.timeline("order", Integer.to_string(order_id), limit: 1)
    assert [%{to_state: "refunded"} = entry] = page.entries
    assert page.next_page == 2
    assert entry.entity_type == "Order"
    assert entry.entity_id == Integer.to_string(order_id)
    refute_unsafe(page)

    assert {:ok, second_page} =
             AuditViews.timeline("order", Integer.to_string(order_id), limit: 1, page: 2)

    assert [%{to_state: "manual_review"}] = second_page.entries
  end

  test "state transition pagination is applied by the database query" do
    order_id = insert_order!()

    for index <- 1..4 do
      insert_transition!("Order", order_id, "state_#{index}", "state_#{index + 1}",
        seconds_ago: index
      )
    end

    {result, transition_queries} =
      capture_transition_queries(fn ->
        AuditViews.timeline("order", Integer.to_string(order_id), limit: 1, page: 2)
      end)

    assert {:ok, %{entries: [%{to_state: "state_3"}], next_page: 3}} = result

    assert Enum.any?(transition_queries, fn query ->
             String.contains?(query, ~s(FROM "sales_state_transitions")) and
               String.contains?(query, "LIMIT") and String.contains?(query, "OFFSET")
           end)
  end

  test "summary rows do not consume transition pagination budget" do
    order_id = insert_order!()
    payment_attempt_id = insert_payment_attempt!(order_id)

    for index <- 1..3 do
      insert_transition!(
        "PaymentAttempt",
        payment_attempt_id,
        "payment_state_#{index}",
        "payment_state_#{index + 1}",
        seconds_ago: index
      )
    end

    assert {:ok, page_1} =
             AuditViews.timeline("payment_attempt", Integer.to_string(payment_attempt_id),
               limit: 1,
               page: 1
             )

    assert {:ok, page_2} =
             AuditViews.timeline("payment_attempt", Integer.to_string(payment_attempt_id),
               limit: 1,
               page: 2
             )

    assert {:ok, page_3} =
             AuditViews.timeline("payment_attempt", Integer.to_string(payment_attempt_id),
               limit: 1,
               page: 3
             )

    assert Enum.any?(page_1.entries, &(&1.source == "payment_attempt.summary"))

    transition_states =
      [page_1, page_2, page_3]
      |> Enum.flat_map(& &1.entries)
      |> Enum.filter(&(&1.source == "audit_test"))
      |> Enum.map(& &1.to_state)

    assert transition_states == ["payment_state_2", "payment_state_3", "payment_state_4"]
  end

  test "payment, ticket, and delivery summaries redact sensitive fields" do
    order_id = insert_order!()
    offer_id = insert_offer!()
    line_id = insert_order_line!(order_id, offer_id)
    payment_attempt_id = insert_payment_attempt!(order_id)
    payment_event_id = insert_payment_event!("provider-ref-#{order_id}")
    ticket_issue_id = insert_ticket_issue!(order_id, line_id)
    delivery_attempt_id = insert_delivery_attempt!(order_id, ticket_issue_id)

    for {entity_type, entity_id} <- [
          {"payment_attempt", payment_attempt_id},
          {"payment_event", payment_event_id},
          {"ticket_issue", ticket_issue_id},
          {"delivery_attempt", delivery_attempt_id}
        ] do
      assert {:ok, %{entries: [_ | _]} = page} =
               AuditViews.timeline(entity_type, Integer.to_string(entity_id), limit: 5)

      refute_unsafe(page)
    end
  end

  test "payment event timeline does not expose raw processing errors as reason text" do
    payment_event_id = insert_payment_event!("provider-ref-raw-error")

    assert {:ok, %{entries: [entry]}} =
             AuditViews.timeline("payment_event", Integer.to_string(payment_event_id), limit: 5)

    assert entry.reason_code == "manual_review"
    refute inspect(entry) =~ @raw_processing_error
  end

  defp refute_unsafe(term) do
    encoded = inspect(term)

    for unsafe <- [
          @raw_email,
          @raw_phone,
          @authorization_url,
          @access_code,
          @ticket_code,
          @qr_hash,
          @delivery_hash,
          @idempotency_key,
          @raw_processing_error,
          "raw_payload",
          "raw_initialize_response",
          "raw_verify_response",
          "raw provider message"
        ] do
      refute encoded =~ unsafe
    end
  end

  defp insert_order! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, manual_review_reason,
           inserted_at, updated_at)
        VALUES
          ($1, 21022, 'Audit Buyer', $2, $3, 'admin', 'manual_review',
           10000, 'ZAR', $4, 'audit_review', now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          "FC-AUDIT-#{System.unique_integer([:positive])}",
          @raw_phone,
          @raw_email,
          @idempotency_key
        ]
      )

    id
  end

  defp insert_offer! do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          (21022, $1, 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        ["Audit offer #{System.unique_integer([:positive])}"]
      )

    id
  end

  defp insert_order_line!(order_id, offer_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'General', 'Audit offer', 'Audit Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id]
      )

    id
  end

  defp insert_transition!(entity_type, entity_id, from_state, to_state, opts) do
    seconds_ago = Keyword.fetch!(opts, :seconds_ago)

    Repo.query!(
      """
      INSERT INTO sales_state_transitions
        (entity_type, entity_id, from_state, to_state, reason, actor_type, actor_id,
         metadata, correlation_id, request_id, idempotency_key, source, inserted_at)
      VALUES
        ($1, $2, $3, $4, 'audit_reason', 'admin', $5,
         $6, 'corr-audit', 'req-audit', $7, 'audit_test',
         now() AT TIME ZONE 'utc' - make_interval(secs => $8::int))
      """,
      [
        entity_type,
        Integer.to_string(entity_id),
        from_state,
        to_state,
        @raw_email,
        Jason.encode!(%{
          buyer_email: @raw_email,
          buyer_phone: @raw_phone,
          authorization_url: @authorization_url,
          raw_payload: %{"secret" => "payload"}
        }),
        @idempotency_key,
        seconds_ago
      ]
    )
  end

  defp insert_payment_attempt!(order_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_payment_attempts
          (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
           access_code, status, amount_cents, currency, verification_attempt_count,
           manual_review_reason, raw_initialize_response, raw_verify_response, inserted_at, updated_at)
        VALUES
          ($1, 'paystack', $2, $3, $4, $5, 'manual_review', 10000, 'ZAR', 1,
           'audit_payment_review', '{"secret":"raw-init"}', '{"secret":"raw-verify"}',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, "provider-ref-#{order_id}", @idempotency_key, @authorization_url, @access_code]
      )

    id
  end

  defp insert_payment_event!(provider_reference) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_payment_events
          (provider, provider_event_id, provider_reference, event_type, signature_valid,
           payload_hash, raw_payload, received_at, processing_status, processing_attempt_count,
           last_processing_error, inserted_at, updated_at)
        VALUES
          ('paystack', $1, $2, 'charge.success', true, $3, '{"secret":"raw-payload"}',
           now() AT TIME ZONE 'utc', 'manual_review', 1, $4, now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          "evt-#{System.unique_integer([:positive])}",
          provider_reference,
          "payload-#{System.unique_integer([:positive])}",
          @raw_processing_error
        ]
      )

    id
  end

  defp capture_transition_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "audit-views-test-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, metadata, _config ->
        if is_binary(metadata.query) and
             String.contains?(metadata.query, ~s(FROM "sales_state_transitions")) do
          send(parent, {:transition_query, ref, metadata.query})
        end
      end,
      nil
    )

    result = fun.()
    queries = drain_transition_queries(ref, [])

    :telemetry.detach(handler_id)

    {result, Enum.reverse(queries)}
  end

  defp drain_transition_queries(ref, queries) do
    receive do
      {:transition_query, ^ref, query} -> drain_transition_queries(ref, [query | queries])
    after
      0 -> queries
    end
  end

  defp insert_ticket_issue!(order_id, line_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           qr_token_hash, delivery_token_hash, status, scanner_status, issued_at,
           inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 112233, $3, $4, $5, 'issued', 'valid',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, line_id, @ticket_code, @qr_hash, @delivery_hash]
      )

    id
  end

  defp insert_delivery_attempt!(order_id, ticket_issue_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_delivery_attempts
          (sales_order_id, ticket_issue_id, channel, provider, recipient, status,
           template_name, attempt_number, provider_error_message, failure_reason,
           inserted_at, updated_at)
        VALUES
          ($1, $2, 'whatsapp', 'meta', $3, 'failed', 'ticket_ready_af', 1,
           'raw provider message', 'audit delivery failure',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, ticket_issue_id, @raw_phone]
      )

    id
  end
end
