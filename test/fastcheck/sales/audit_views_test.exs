defmodule FastCheck.Sales.AuditViewsTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.AuditViews
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

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
    actor = actor()
    assert {:error, :invalid_entity_type} = AuditViews.timeline(actor, "unknown", "123")
    assert {:error, :invalid_entity_id} = AuditViews.timeline(actor, "order", "not-an-id")
  end

  test "order timeline is newest first, paginated, and redacted" do
    order_id = insert_order!()
    actor = actor()

    insert_transition!("Order", order_id, "draft", "manual_review", seconds_ago: 60)
    insert_transition!("Order", order_id, "manual_review", "refunded", seconds_ago: 5)
    insert_payment_attempt!(order_id)

    assert {:ok, page} =
             AuditViews.timeline(actor, "order", Integer.to_string(order_id), limit: 1)

    assert [%{to_state: "refunded"} = entry] = page.entries
    assert page.next_page == 2
    assert entry.entity_type == "Order"
    assert entry.entity_id == Integer.to_string(order_id)
    refute_unsafe(page)

    assert {:ok, second_page} =
             AuditViews.timeline(actor, "order", Integer.to_string(order_id), limit: 1, page: 2)

    assert [%{to_state: "manual_review"}] = second_page.entries
  end

  test "state transition pagination is applied by the database query" do
    order_id = insert_order!()
    actor = actor()

    for index <- 1..4 do
      insert_transition!("Order", order_id, "state_#{index}", "state_#{index + 1}",
        seconds_ago: index
      )
    end

    {result, transition_queries} =
      capture_transition_queries(fn ->
        AuditViews.timeline(actor, "order", Integer.to_string(order_id), limit: 1, page: 2)
      end)

    assert {:ok, %{entries: [%{to_state: "state_3"}], next_page: 3}} = result

    assert Enum.any?(transition_queries, fn query ->
             String.contains?(query, ~s(FROM "sales_state_transitions")) and
               String.contains?(query, "LIMIT") and String.contains?(query, "OFFSET")
           end)
  end

  test "summary rows do not consume transition pagination budget" do
    order_id = insert_order!()
    actor = actor()
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
             AuditViews.timeline(actor, "payment_attempt", Integer.to_string(payment_attempt_id),
               limit: 1,
               page: 1
             )

    assert {:ok, page_2} =
             AuditViews.timeline(actor, "payment_attempt", Integer.to_string(payment_attempt_id),
               limit: 1,
               page: 2
             )

    assert {:ok, page_3} =
             AuditViews.timeline(actor, "payment_attempt", Integer.to_string(payment_attempt_id),
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
    actor = actor()
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
               AuditViews.timeline(actor, entity_type, Integer.to_string(entity_id), limit: 5)

      refute_unsafe(page)
    end
  end

  test "unmatched payment events are unavailable to event scoped audit users" do
    actor = actor()
    payment_event_id = insert_payment_event!("provider-ref-raw-error")

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "payment_event", Integer.to_string(payment_event_id),
               limit: 5
             )
  end

  test "conversation ownership ignores state_data and rejects cross-event ambiguity" do
    actor = actor()

    granted_wa_id = "audit-granted-#{System.unique_integer([:positive])}"
    granted_conversation_id = insert_conversation!(granted_wa_id, %{})
    granted_order_id = insert_order!(21_022)
    attach_order_to_conversation!(granted_order_id, granted_wa_id)

    assert {:ok, %{entries: _}} =
             AuditViews.timeline(actor, "conversation", granted_conversation_id)

    conversation_transition_id =
      insert_transition!("conversation", granted_conversation_id, "new", "menu", seconds_ago: 4)

    assert {:ok, %{entries: [%{to_state: "menu"}]}} =
             AuditViews.timeline(actor, "state_transition", conversation_transition_id)

    orphan_wa_id = "audit-orphan-#{System.unique_integer([:positive])}"
    orphan_conversation_id = insert_conversation!(orphan_wa_id, %{"selected_event_id" => 21_022})

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "conversation", orphan_conversation_id)

    foreign_wa_id = "audit-foreign-#{System.unique_integer([:positive])}"

    foreign_conversation_id =
      insert_conversation!(foreign_wa_id, %{"selected_event_id" => 21_022})

    foreign_order_id = insert_order!(21_024)
    attach_order_to_conversation!(foreign_order_id, foreign_wa_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "conversation", foreign_conversation_id)

    shared_wa_id = "audit-shared-#{System.unique_integer([:positive])}"
    shared_conversation_id = insert_conversation!(shared_wa_id, %{})
    granted_order_id = insert_order!(21_022)
    other_event_order_id = insert_order!(21_024)
    attach_order_to_conversation!(granted_order_id, shared_wa_id)
    attach_order_to_conversation!(other_event_order_id, shared_wa_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "conversation", shared_conversation_id)
  end

  test "payment events linked to another event are unavailable" do
    event_b_order_id = insert_order!(21_024)
    payment_attempt_id = insert_payment_attempt!(event_b_order_id)
    reference = "provider-ref-#{event_b_order_id}"
    payment_event_id = insert_payment_event!(reference)

    assert {:error, :not_found} =
             AuditViews.timeline(actor(), "payment_event", payment_event_id)

    assert payment_attempt_id > 0
  end

  test "guessed entities from another event are indistinguishable from unavailable entities" do
    event_a_order_id = insert_order!()
    event_b_order_id = insert_order!(21_024)
    actor = actor()
    checkout_session_id = insert_checkout_session!(event_b_order_id)
    payment_attempt_id = insert_payment_attempt!(event_b_order_id)
    payment_event_id = insert_payment_event!("provider-ref-#{event_b_order_id}")
    offer_id = insert_offer!(21_024)
    line_id = insert_order_line!(event_b_order_id, offer_id)
    ticket_issue_id = insert_ticket_issue!(event_b_order_id, line_id)
    delivery_attempt_id = insert_delivery_attempt!(event_b_order_id, ticket_issue_id)
    attendee = insert_attendee!(21_024)
    invalidation_id = insert_invalidation!(21_024, attendee.id)
    wa_id = "audit-foreign-#{System.unique_integer([:positive])}"
    conversation_id = insert_conversation!(wa_id, %{"selected_event_id" => 21_022})
    attach_order_to_conversation!(event_b_order_id, wa_id)

    transition_id =
      insert_transition!("Order", event_b_order_id, "draft", "manual_review", seconds_ago: 3)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "order", Integer.to_string(event_b_order_id))

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "checkout_session", checkout_session_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "payment_attempt", Integer.to_string(payment_attempt_id))

    assert {:error, :not_found} = AuditViews.timeline(actor, "payment_event", payment_event_id)
    assert {:error, :not_found} = AuditViews.timeline(actor, "ticket_issue", ticket_issue_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "delivery_attempt", delivery_attempt_id)

    assert {:error, :not_found} = AuditViews.timeline(actor, "conversation", conversation_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "attendee_invalidation_event", invalidation_id)

    assert {:error, :not_found} = AuditViews.timeline(actor, "state_transition", transition_id)

    assert {:ok, %{entries: _}} =
             AuditViews.timeline(actor, "order", Integer.to_string(event_a_order_id))
  end

  test "state transition lookup proves the referenced order event before returning details" do
    event_a_order_id = insert_order!()
    event_b_order_id = insert_order!(21_024)
    actor = actor()

    event_a_transition_id =
      insert_transition!("Order", event_a_order_id, "draft", "manual_review", seconds_ago: 5)

    event_b_transition_id =
      insert_transition!("Order", event_b_order_id, "draft", "manual_review", seconds_ago: 3)

    assert {:ok, %{entries: [%{to_state: "manual_review"}]}} =
             AuditViews.timeline(actor, "state_transition", event_a_transition_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "state_transition", event_b_transition_id)
  end

  test "refund state transitions prove event ownership through the refund order" do
    event_a_order_id = insert_order!()
    event_b_order_id = insert_order!(21_024)
    event_a_payment_attempt_id = insert_payment_attempt!(event_a_order_id)
    event_b_payment_attempt_id = insert_payment_attempt!(event_b_order_id)
    event_a_refund_id = insert_refund!(event_a_order_id, event_a_payment_attempt_id)
    event_b_refund_id = insert_refund!(event_b_order_id, event_b_payment_attempt_id)
    actor = actor()

    event_a_transition_id =
      insert_transition!("Refund", event_a_refund_id, nil, "evidence_recorded", seconds_ago: 5)

    event_b_transition_id =
      insert_transition!("Refund", event_b_refund_id, nil, "evidence_recorded", seconds_ago: 3)

    assert {:ok, %{entries: [%{to_state: "evidence_recorded"}]}} =
             AuditViews.timeline(actor, "state_transition", event_a_transition_id)

    assert {:error, :not_found} =
             AuditViews.timeline(actor, "state_transition", event_b_transition_id)
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

  defp actor, do: WebFixtures.dashboard_actor([21_022])

  defp insert_order!(event_id \\ 21_022) do
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(event_id)
    idempotency_key = "#{@idempotency_key}-#{System.unique_integer([:positive])}"

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, manual_review_reason,
           inserted_at, updated_at)
        VALUES
          ($1, $2, 'Audit Buyer', $3, $4, 'admin', 'manual_review',
           10000, 'ZAR', $5, 'audit_review', now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          "FC-AUDIT-#{System.unique_integer([:positive])}",
          event_id,
          @raw_phone,
          @raw_email,
          idempotency_key
        ]
      )

    id
  end

  defp insert_offer!(event_id \\ 21_022) do
    FastCheck.SalesCheckoutFixtures.ensure_event_for_sales!(event_id)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           lock_version, inserted_at, updated_at)
        VALUES
          ($1, $2, 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id, "Audit offer #{System.unique_integer([:positive])}"]
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

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_state_transitions
          (entity_type, entity_id, from_state, to_state, reason, actor_type, actor_id,
           metadata, correlation_id, request_id, idempotency_key, source, inserted_at)
        VALUES
          ($1, $2, $3, $4, 'audit_reason', 'admin', $5,
           $6, 'corr-audit', 'req-audit', $7, 'audit_test',
             now() AT TIME ZONE 'utc' - make_interval(secs => $8::int))
        RETURNING id
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

    id
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

  defp insert_refund!(order_id, payment_attempt_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_refunds
          (sales_order_id, payment_attempt_id, provider, provider_status,
           provider_refund_reference, provider_refunded_at, amount_cents, currency,
           status, recorded_by, reason, inserted_at, updated_at)
        VALUES ($1, $2, 'paystack', 'processed', $3, now(), 10000, 'ZAR',
                'evidence_recorded', 'audit-test', 'Audit refund', now(), now())
        RETURNING id
        """,
        [order_id, payment_attempt_id, "refund-ref-#{order_id}"]
      )

    id
  end

  defp insert_conversation!(wa_id, state_data) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, preferred_language, state, state_data, needs_human,
           inserted_at, updated_at)
        VALUES ('+27821234567', $1, 'en', 'new', $2::jsonb, false, now(), now())
        RETURNING id
        """,
        [wa_id, Jason.encode!(state_data)]
      )

    id
  end

  defp attach_order_to_conversation!(order_id, wa_id) do
    Repo.query!(
      """
      UPDATE sales_orders
      SET sales_conversation_id = (SELECT id FROM sales_conversations WHERE wa_id = $1),
          whatsapp_conversation_id = $1
      WHERE id = $2
      """,
      [wa_id, order_id]
    )
  end

  defp insert_checkout_session!(order_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_checkout_sessions
          (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
        VALUES ($1, 'paid', 1, '{}', 1, now(), now())
        RETURNING id
        """,
        [order_id]
      )

    id
  end

  defp insert_attendee!(event_id) do
    %Attendee{}
    |> Attendee.changeset(%{
      event_id: event_id,
      ticket_code: "AUDIT-ATTENDEE-#{System.unique_integer([:positive])}",
      first_name: "Audit",
      last_name: "Guest",
      payment_status: "paid"
    })
    |> Repo.insert!()
  end

  defp insert_invalidation!(event_id, attendee_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO attendee_invalidation_events
          (event_id, attendee_id, ticket_code, change_type, reason_code, effective_at, inserted_at)
        VALUES ($1, $2, 'AUDIT-INVALIDATED', 'not_scannable', 'revoked', now(), now())
        RETURNING id
        """,
        [event_id, attendee_id]
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
