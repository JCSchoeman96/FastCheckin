defmodule FastCheck.Sales.AdminDashboardTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.AdminDashboard

  @raw_email "sensitive.buyer@example.com"
  @raw_phone "+27123456789"
  @raw_buyer_name "Sensitive Buyer Name"
  @access_code "ACCESS_SECRET_123"
  @authorization_url "https://checkout.paystack.test/pay/secret"
  @ticket_code "TICKET-SECRET-001"
  @qr_hash "qr-secret-hash"
  @delivery_hash "delivery-secret-hash"
  @idempotency_key "idem-secret-key"

  test "summary is bounded by the default window and exposes only safe counts" do
    event_id = 12_001
    recent = insert_sales_order!(event_id, "FC-RECENT", "paid_verified", days_ago: 1)
    _old = insert_sales_order!(event_id, "FC-OLD", "paid_verified", days_ago: 45)
    manual = insert_sales_order!(event_id, "FC-MANUAL", "manual_review", days_ago: 120)

    insert_payment_attempt!(recent.id, "verified_success")
    insert_checkout_session!(recent.id, "paid")
    line_id = insert_order_line!(recent.id, insert_offer!(event_id))
    insert_ticket_issue!(recent.id, line_id, "issued")

    insert_payment_attempt!(manual.id, "manual_review",
      manual_review_reason: "payment_state_conflict"
    )

    summary = AdminDashboard.summary(%{"event_id" => to_string(event_id)})

    assert summary.orders_in_window == 1
    assert summary.paid_verified == 1
    assert summary.issued == 1
    assert summary.manual_review_open == 1
    refute unsafe_value_present?(summary)
  end

  test "recent_orders applies limits, stable ordering, safe masks, and public-reference search only" do
    event_id = 12_002
    old = insert_sales_order!(event_id, "FC-ORDER-OLD", "paid_verified", days_ago: 2)
    newest = insert_sales_order!(event_id, "FC-ORDER-NEW", "manual_review", days_ago: 0)
    _phone_match = insert_sales_order!(event_id, @raw_phone, "paid_verified", days_ago: 0)

    insert_payment_attempt!(newest.id, "verified_amount_mismatch")
    insert_payment_attempt!(old.id, "verified_success")

    assert [order] =
             AdminDashboard.recent_orders(
               %{"event_id" => to_string(event_id), "search" => "FC-ORDER"},
               limit: 1
             )

    assert order.order_public_reference == "FC-ORDER-NEW"
    refute inspect(order) =~ @raw_buyer_name
    refute Map.has_key?(order, :buyer_name)
    assert order.buyer_display_name == "Buyer"
    assert order.buyer_email_masked != @raw_email
    assert order.buyer_phone_masked != @raw_phone
    refute Map.has_key?(order, :buyer_email)
    refute Map.has_key?(order, :buyer_phone)
    refute unsafe_value_present?(order)

    assert [] =
             AdminDashboard.recent_orders(
               %{"event_id" => to_string(event_id), "search" => @raw_phone},
               limit: 25
             )
  end

  test "invalid date filters do not broaden recent order results" do
    event_id = 12_003
    _old = insert_sales_order!(event_id, "FC-DATE-OLD", "paid_verified", days_ago: 180)

    assert [] =
             AdminDashboard.recent_orders(
               %{
                 "event_id" => to_string(event_id),
                 "from_date" => "not-a-date",
                 "to_date" => "also-not-a-date"
               },
               limit: 25
             )
  end

  test "manual_review_queue returns bounded safe review rows without raw PaymentEvent payloads" do
    event_id = 12_004
    order = insert_sales_order!(event_id, "FC-REVIEW", "manual_review", days_ago: 0)
    insert_checkout_session!(order.id, "manual_review")

    insert_payment_attempt!(order.id, "manual_review",
      manual_review_reason: "payment_state_conflict"
    )

    insert_payment_event!("provider-ref-#{order.id}", "manual_review")

    assert [review] = AdminDashboard.manual_review_queue(%{"event_id" => to_string(event_id)})

    assert review.order_public_reference == "FC-REVIEW"
    assert review.reason_code == "payment_state_conflict"
    assert review.payment_event_status_summary == %{"manual_review" => 1}
    refute inspect(review) =~ @raw_buyer_name
    refute unsafe_value_present?(review)
  end

  test "order_detail returns safe linkage counts and not sensitive fields" do
    event_id = 12_005
    order = insert_sales_order!(event_id, "FC-DETAIL", "ticket_issued", days_ago: 0)
    offer_id = insert_offer!(event_id)
    line_id = insert_order_line!(order.id, offer_id)
    insert_checkout_session!(order.id, "paid")
    insert_payment_attempt!(order.id, "verified_success")
    insert_ticket_issue!(order.id, line_id, "issued")

    assert {:ok, detail} = AdminDashboard.order_detail(order.id)

    assert detail.order_public_reference == "FC-DETAIL"
    assert detail.ticket_issue_count == 1
    assert detail.issued_ticket_count == 1
    assert detail.attendee_link_count == 1
    refute inspect(detail) =~ @raw_buyer_name
    refute unsafe_value_present?(detail)
  end

  defp unsafe_value_present?(term) do
    encoded = inspect(term)

    Enum.any?(
      [
        @raw_email,
        @raw_phone,
        @access_code,
        @authorization_url,
        @ticket_code,
        @qr_hash,
        @delivery_hash,
        @idempotency_key,
        "raw_payload",
        "raw_initialize_response",
        "raw_verify_response"
      ],
      &String.contains?(encoded, &1)
    )
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
          ($1, 'Dashboard offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id]
      )

    id
  end

  defp insert_sales_order!(event_id, public_reference, status, opts) do
    days_ago = Keyword.fetch!(opts, :days_ago)
    reason = if status == "manual_review", do: "payment_state_conflict", else: nil

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, manual_review_reason,
           inserted_at, updated_at)
        VALUES
          ($1, $2, $3, $4, $5, 'admin', $6, 10000, 'ZAR', $7, $8,
           now() AT TIME ZONE 'utc' - make_interval(days => $9::int),
           now() AT TIME ZONE 'utc' - make_interval(days => $9::int))
        RETURNING id
        """,
        [
          public_reference,
          event_id,
          @raw_buyer_name,
          @raw_phone,
          @raw_email,
          status,
          "#{@idempotency_key}-#{public_reference}",
          reason,
          days_ago
        ]
      )

    %{id: id, public_reference: public_reference}
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
          ($1, $2, 1, 'General', 'Dashboard offer', 'Dashboard Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id]
      )

    id
  end

  defp insert_checkout_session!(order_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_token, hold_quantity, state_data,
         lock_version, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, 'secret-hold-token', 1, '{}', 1, now() AT TIME ZONE 'utc',
         now() AT TIME ZONE 'utc')
      """,
      [order_id, status, "hold-#{order_id}"]
    )
  end

  defp insert_payment_attempt!(order_id, status, opts \\ []) do
    reason = Keyword.get(opts, :manual_review_reason)

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         manual_review_reason, raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, $3, $4, $5, $6, 10000, 'ZAR', 1, $7,
         '{"secret":"raw-init"}', '{"secret":"raw-verify"}', now() AT TIME ZONE 'utc',
         now() AT TIME ZONE 'utc')
      """,
      [
        order_id,
        "provider-ref-#{order_id}",
        @idempotency_key,
        @authorization_url,
        @access_code,
        status,
        reason
      ]
    )
  end

  defp insert_payment_event!(provider_reference, status) do
    Repo.query!(
      """
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, signature_valid,
         payload_hash, raw_payload, received_at, processing_status, processing_attempt_count,
         inserted_at, updated_at)
      VALUES
        ('paystack', $1, $2, 'charge.success', true, $3, '{"secret":"raw-payload"}',
         now() AT TIME ZONE 'utc', $4, 1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [
        "evt-#{System.unique_integer([:positive])}",
        provider_reference,
        "payload-#{System.unique_integer([:positive])}",
        status
      ]
    )
  end

  defp insert_ticket_issue!(order_id, line_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, issued_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 987654, $3, $4, $5, $6, 'valid', now() AT TIME ZONE 'utc',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, line_id, @ticket_code, @qr_hash, @delivery_hash, status]
    )
  end
end
