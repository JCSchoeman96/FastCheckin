defmodule FastCheck.Sales.Vs01fPolicyTest do
  use FastCheck.DataCase, async: true

  alias Ash.Query
  alias Ash.Resource.Info, as: ResourceInfo

  @event_id 101
  @other_event_id 202

  @event_scoped_resources [
    FastCheck.Sales.TicketOffer,
    FastCheck.Sales.Order,
    FastCheck.Sales.OrderLine,
    FastCheck.Sales.CheckoutSession,
    FastCheck.Sales.PaymentAttempt,
    FastCheck.Sales.TicketIssue,
    FastCheck.Sales.DeliveryAttempt
  ]

  @system_only_resources [
    FastCheck.Sales.PaymentEvent,
    FastCheck.Sales.StateTransition,
    FastCheck.Sales.Conversation
  ]

  setup do
    insert_sales_graph!(@event_id)
    :ok
  end

  test "customer_session cannot broadly read any Sales resource" do
    for resource <- @event_scoped_resources ++ @system_only_resources do
      assert_forbidden_read(resource, customer_session_actor())
    end
  end

  test "admin and operator reads are filtered by allowed events for scoped resources" do
    for resource <- @event_scoped_resources do
      assert [_record] = read(resource, admin_actor([@event_id]))
      assert [_record] = read(resource, operator_actor([@event_id]))

      assert [] = read(resource, admin_actor([@other_event_id]))
      assert [] = read(resource, operator_actor([@other_event_id]))
    end
  end

  test "resources without reliable event scope are not broadly readable by admin or operator" do
    for resource <- @system_only_resources do
      assert_forbidden_read(resource, admin_actor([@event_id]))
      assert_forbidden_read(resource, operator_actor([@event_id]))
      assert [_record] = read(resource, system_actor())
    end
  end

  test "operator cannot access restricted payment fields" do
    assert [attempt] =
             read(FastCheck.Sales.PaymentAttempt, operator_actor([@event_id]),
               select: [
                 :id,
                 :authorization_url,
                 :access_code,
                 :raw_initialize_response,
                 :raw_verify_response
               ]
             )

    assert %Ash.ForbiddenField{} = attempt.authorization_url
    assert %Ash.ForbiddenField{} = attempt.access_code
    assert %Ash.ForbiddenField{} = attempt.raw_initialize_response
    assert %Ash.ForbiddenField{} = attempt.raw_verify_response

    assert [attempt] =
             read(FastCheck.Sales.PaymentAttempt, admin_actor([@event_id]),
               select: [
                 :id,
                 :authorization_url,
                 :access_code,
                 :raw_initialize_response,
                 :raw_verify_response
               ]
             )

    assert attempt.authorization_url == "https://paystack.example/checkout"
    assert attempt.access_code == "paystack-access-code"
    assert attempt.raw_initialize_response == %{"provider" => "initialize"}
    assert attempt.raw_verify_response == %{"provider" => "verify"}
  end

  test "operator cannot access restricted ticket and delivery fields" do
    assert [ticket_issue] =
             read(FastCheck.Sales.TicketIssue, operator_actor([@event_id]),
               select: [:id, :ticket_code, :qr_token_hash, :delivery_token_hash, :attendee_id]
             )

    assert %Ash.ForbiddenField{} = ticket_issue.ticket_code
    assert %Ash.ForbiddenField{} = ticket_issue.qr_token_hash
    assert %Ash.ForbiddenField{} = ticket_issue.delivery_token_hash
    assert %Ash.ForbiddenField{} = ticket_issue.attendee_id

    assert [delivery_attempt] =
             read(FastCheck.Sales.DeliveryAttempt, operator_actor([@event_id]),
               select: [:id, :recipient, :provider_error_message, :failure_reason]
             )

    assert %Ash.ForbiddenField{} = delivery_attempt.recipient
    assert %Ash.ForbiddenField{} = delivery_attempt.provider_error_message
    assert %Ash.ForbiddenField{} = delivery_attempt.failure_reason
  end

  test "operator cannot access restricted order and checkout fields" do
    assert [order] =
             read(FastCheck.Sales.Order, operator_actor([@event_id]),
               select: [:id, :buyer_name, :buyer_phone, :buyer_email]
             )

    assert %Ash.ForbiddenField{} = order.buyer_name
    assert %Ash.ForbiddenField{} = order.buyer_phone
    assert %Ash.ForbiddenField{} = order.buyer_email

    assert [checkout_session] =
             read(FastCheck.Sales.CheckoutSession, operator_actor([@event_id]),
               select: [:id, :hold_token, :state_data]
             )

    assert %Ash.ForbiddenField{} = checkout_session.hold_token
    assert %Ash.ForbiddenField{} = checkout_session.state_data
  end

  test "system can access system-only restricted provider and conversation fields" do
    assert [payment_event] =
             read(FastCheck.Sales.PaymentEvent, system_actor(),
               select: [:id, :raw_payload, :last_processing_error]
             )

    assert payment_event.raw_payload == %{"event" => "charge.success"}
    assert payment_event.last_processing_error == "provider detail"

    assert [conversation] =
             read(FastCheck.Sales.Conversation, system_actor(),
               select: [
                 :id,
                 :phone_e164,
                 :wa_id,
                 :session_key,
                 :rate_limit_key,
                 :state_data,
                 :last_inbound_message_id,
                 :last_outbound_message_id,
                 :handoff_reason
               ]
             )

    assert conversation.phone_e164 == "+27821234567"
    assert conversation.wa_id == "wa-test"
    assert conversation.session_key == "session:test"
    assert conversation.rate_limit_key == "rate:test"
    assert conversation.state_data == %{"step" => "main_menu"}
    assert conversation.last_inbound_message_id == "wamid-in"
    assert conversation.last_outbound_message_id == "wamid-out"
    assert conversation.handoff_reason == "needs support"
  end

  test "StateTransition remains append-only from the exposed action surface" do
    refute ResourceInfo.action(FastCheck.Sales.StateTransition, :create)
    refute ResourceInfo.action(FastCheck.Sales.StateTransition, :update)
    refute ResourceInfo.action(FastCheck.Sales.StateTransition, :destroy)
    refute ResourceInfo.action(FastCheck.Sales.StateTransition, :update_status)
    refute ResourceInfo.action(FastCheck.Sales.StateTransition, :update_state)
  end

  test "missing or unknown actors fail closed" do
    assert_forbidden_read(FastCheck.Sales.Order, nil)

    assert_forbidden_read(FastCheck.Sales.Order, %{
      actor_type: :auditor,
      allowed_event_ids: [@event_id]
    })
  end

  defp read(resource, actor, opts \\ []) do
    query =
      resource
      |> Query.for_read(:read, %{}, actor: actor, authorize?: true)
      |> maybe_select(Keyword.get(opts, :select))

    Ash.read!(query, authorize?: true)
  end

  defp assert_forbidden_read(resource, actor) do
    assert_raise Ash.Error.Forbidden, fn ->
      query = Query.for_read(resource, :read, %{}, actor: actor, authorize?: true)
      Ash.read!(query, authorize?: true, authorize_with: :error)
    end
  end

  defp maybe_select(query, nil), do: query
  defp maybe_select(query, fields), do: Query.select(query, fields)

  defp system_actor do
    %{actor_type: :system, actor_id: "system"}
  end

  defp admin_actor(event_ids) do
    %{actor_type: :admin, user_id: "admin-1", allowed_event_ids: event_ids}
  end

  defp operator_actor(event_ids) do
    %{actor_type: :operator, user_id: "operator-1", allowed_event_ids: event_ids}
  end

  defp customer_session_actor do
    %{
      actor_type: :customer_session,
      actor_id: "customer-session-1",
      allowed_event_ids: [@event_id]
    }
  end

  defp insert_sales_graph!(event_id) do
    offer_id = insert_ticket_offer!(event_id)
    conversation_id = insert_conversation!()
    order_id = insert_order!(event_id, conversation_id)
    order_line_id = insert_order_line!(order_id, offer_id)
    insert_checkout_session!(order_id)
    insert_payment_attempt!(order_id)
    insert_payment_event!()
    ticket_issue_id = insert_ticket_issue!(order_id, order_line_id)
    insert_delivery_attempt!(order_id, ticket_issue_id)
    insert_state_transition!(order_id)
  end

  defp insert_ticket_offer!(event_id) do
    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_offers
          (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
           initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
           inserted_at, updated_at)
        VALUES
          ($1, $2, 'general', 100, 'ZAR', 10, 10, 2, true, 'whatsapp', now(), now(), now(), now())
        RETURNING id
        """,
        [event_id, "General #{System.unique_integer([:positive])}"]
      )

    [[id]] = result.rows
    id
  end

  defp insert_conversation! do
    result =
      Repo.query!(
        """
        INSERT INTO sales_conversations
          (phone_e164, wa_id, session_key, rate_limit_key, preferred_language, state,
           state_data, last_inbound_message_id, last_outbound_message_id, needs_human,
           handoff_reason, inserted_at, updated_at)
        VALUES
          ('+27821234567', 'wa-test', 'session:test', 'rate:test', 'af', 'main_menu',
           '{"step":"main_menu"}', 'wamid-in', 'wamid-out', true, 'needs support', now(), now())
        RETURNING id
        """,
        []
      )

    [[id]] = result.rows
    id
  end

  defp insert_order!(event_id, conversation_id) do
    result =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, sales_conversation_id, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer Name', '+27825550123', 'buyer@example.com', 'whatsapp',
           'draft', 100, 'ZAR', $3, now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}", event_id, conversation_id]
      )

    [[id]] = result.rows
    id
  end

  defp insert_order_line!(order_id, offer_id) do
    result =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'general', 'General', 'Event', 1, 100, 100, 'ZAR', now(), now())
        RETURNING id
        """,
        [order_id, offer_id]
      )

    [[id]] = result.rows
    id
  end

  defp insert_checkout_session!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_token, hold_quantity, state_data,
         lock_version, inserted_at, updated_at)
      VALUES
        ($1, 'created', 'hold:test', 'hold-token-secret', 1, '{"checkout":"state"}', 1, now(), now())
      """,
      [order_id]
    )
  end

  defp insert_payment_attempt!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, 'idem-test', 'https://paystack.example/checkout',
         'paystack-access-code', 'initialized', 100, 'ZAR', 0,
         '{"provider":"initialize"}', '{"provider":"verify"}', now(), now())
      """,
      [order_id, "ref-#{System.unique_integer([:positive])}"]
    )
  end

  defp insert_payment_event! do
    Repo.query!(
      """
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, payload_hash,
         raw_payload, processing_status, processing_attempt_count, last_processing_error,
         inserted_at, updated_at)
      VALUES
        ('paystack', $1, 'ref-test', 'charge.success', $2,
         '{"event":"charge.success"}', 'stored', 0, 'provider detail', now(), now())
      """,
      [
        "evt-#{System.unique_integer([:positive])}",
        "hash-#{System.unique_integer([:positive])}"
      ]
    )
  end

  defp insert_ticket_issue!(order_id, order_line_id) do
    result =
      Repo.query!(
        """
        INSERT INTO sales_ticket_issues
          (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
           qr_token_hash, delivery_token_hash, status, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 12345, $3, 'qr-token-hash', 'delivery-token-hash', 'issued', now(), now())
        RETURNING id
        """,
        [order_id, order_line_id, "TICKET-#{System.unique_integer([:positive])}"]
      )

    [[id]] = result.rows
    id
  end

  defp insert_delivery_attempt!(order_id, ticket_issue_id) do
    Repo.query!(
      """
      INSERT INTO sales_delivery_attempts
        (sales_order_id, ticket_issue_id, channel, provider, recipient, status, attempt_number,
         provider_error_message, failure_reason, inserted_at, updated_at)
      VALUES
        ($1, $2, 'whatsapp', 'meta', '+27825550123', 'queued', 1,
         'provider says no', 'customer detail', now(), now())
      """,
      [order_id, ticket_issue_id]
    )
  end

  defp insert_state_transition!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_state_transitions
        (entity_type, entity_id, from_state, to_state, reason, actor_type, actor_id,
         metadata, inserted_at)
      VALUES
        ('order', $1, 'draft', 'awaiting_payment', 'test transition', 'system',
         'system', '{}', now())
      """,
      [to_string(order_id)]
    )
  end
end
