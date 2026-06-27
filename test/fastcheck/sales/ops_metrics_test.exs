defmodule FastCheck.Sales.OpsMetricsTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Repo
  alias FastCheck.Sales.OpsMetrics

  @event_id 21_021
  @raw_email "ops.raw@example.com"
  @raw_phone "+27123456789"
  @ticket_code "OPS-TICKET-SECRET"
  @access_code "OPS_ACCESS_SECRET"
  @authorization_url "https://checkout.paystack.test/pay/ops-secret"
  @qr_hash "ops-qr-hash"
  @delivery_hash "ops-delivery-hash"

  test "summary returns bounded operational counters without sensitive values" do
    insert_event!()
    order = insert_order!("FC-OPS-1", "manual_review", "whatsapp")
    old_order = insert_old_order!("FC-OPS-OLD", "manual_review", "whatsapp")
    offer_id = insert_offer!()
    line_id = insert_order_line!(order.id, offer_id)
    insert_checkout_session!(order.id, "payment_started", minutes_from_now: 10)
    insert_checkout_session!(old_order.id, "expired", minutes_from_now: -180, released_at: nil)
    insert_payment_attempt!(order.id, "verified_amount_mismatch")
    insert_payment_event!("provider-ref-#{order.id}", "unmatched")
    insert_payment_event!("provider-ref-duplicate", "duplicate")
    insert_ticket_issue!(order.id, line_id, "revoked", "revoked")
    insert_delivery_attempt!(order.id, nil, "fallback_required")
    insert_attendee_invalidation!()
    insert_retryable_oban_job!("payments")

    summary = OpsMetrics.summary(%{"event_id" => to_string(@event_id), "window" => "1h"})

    assert summary.window == "1h"
    assert summary.orders_by_status == %{"manual_review" => 1}
    assert summary.orders_by_source_channel == %{"whatsapp" => 1}
    assert summary.checkout_expiring_soon_count == 1
    assert summary.checkout_expired_unreleased_count == 0
    assert summary.payment_attempts_by_status == %{"verified_amount_mismatch" => 1}
    assert summary.payment_mismatch_count == 1
    assert summary.payment_unmatched_event_count == 1
    assert summary.payment_webhook_duplicate_count == 1
    assert summary.tickets_revoked_count == 1
    assert summary.scanner_visibility_pending_count == 1
    assert summary.delivery_attempts_by_status == %{"fallback_required" => 1}
    assert summary.delivery_fallback_required_count == 1
    assert summary.manual_review_open_count == 1
    assert summary.manual_review_oldest_age_seconds >= 0
    assert summary.worker_retry_backlog_by_queue == %{"payments" => 1}
    refute_unsafe(summary)
  end

  test "recent_failures is capped, newest first, and redacted" do
    insert_event!()
    older = insert_order!("FC-OPS-OLDER", "manual_review", "admin", seconds_ago: 60)
    newer = insert_order!("FC-OPS-NEWER", "manual_review", "admin", seconds_ago: 5)
    insert_payment_attempt!(older.id, "failed")
    insert_payment_attempt!(newer.id, "manual_review")

    assert [failure] =
             OpsMetrics.recent_failures(%{"event_id" => to_string(@event_id), "window" => "1h"},
               limit: 1
             )

    assert failure.order_public_reference == "FC-OPS-NEWER"
    assert failure.kind == "payment_attempt"
    refute_unsafe(failure)
  end

  defp refute_unsafe(term) do
    encoded = inspect(term)

    for unsafe <- [
          @raw_email,
          @raw_phone,
          @ticket_code,
          @access_code,
          @authorization_url,
          @qr_hash,
          @delivery_hash,
          "raw_payload",
          "raw_initialize_response",
          "raw_verify_response"
        ] do
      refute encoded =~ unsafe
    end
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
          ($1, $2, 'General', 10000, 'ZAR', 100, 100, 4, true, 'whatsapp',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [@event_id, "Ops offer #{System.unique_integer([:positive])}"]
      )

    id
  end

  defp insert_event! do
    Repo.query!(
      """
      INSERT INTO events
        (id, name, site_url, tickera_site_url, tickera_api_key_encrypted,
         tickera_api_key_last4, mobile_access_secret_encrypted, scanner_login_code,
         status, inserted_at, updated_at)
      VALUES
        ($1, 'Ops Event', 'https://example.test', 'https://example.test',
         'encrypted-api-key', 'ikey', 'encrypted-mobile-secret', $2, 'active',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      ON CONFLICT (id) DO NOTHING
      """,
      [
        @event_id,
        "AA#{rem(@event_id, 10_000) |> Integer.to_string() |> String.pad_leading(4, "0")}"
      ]
    )
  end

  defp insert_order!(public_reference, status, source_channel, opts \\ []) do
    seconds_ago = Keyword.get(opts, :seconds_ago, 0)

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, manual_review_reason, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Ops Buyer', $3, $4, $5, $6, 10000, 'ZAR', 'ops_review',
           now() AT TIME ZONE 'utc' - make_interval(secs => $7::int),
           now() AT TIME ZONE 'utc' - make_interval(secs => $7::int))
        RETURNING id
        """,
        [public_reference, @event_id, @raw_phone, @raw_email, source_channel, status, seconds_ago]
      )

    %{id: id}
  end

  defp insert_old_order!(public_reference, status, source_channel) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, manual_review_reason, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Old Buyer', $3, $4, $5, $6, 10000, 'ZAR', 'old_review',
           now() AT TIME ZONE 'utc' - interval '2 days',
           now() AT TIME ZONE 'utc' - interval '2 days')
        RETURNING id
        """,
        [public_reference, @event_id, @raw_phone, @raw_email, source_channel, status]
      )

    %{id: id}
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
          ($1, $2, 1, 'General', 'Ops offer', 'Ops Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id]
      )

    id
  end

  defp insert_checkout_session!(order_id, status, opts) do
    minutes_from_now = Keyword.fetch!(opts, :minutes_from_now)
    released_at = Keyword.get(opts, :released_at)

    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_token, hold_quantity, expires_at,
         released_at, state_data, lock_version, inserted_at, updated_at)
      VALUES
        ($1, $2, $3, 'secret-hold-token', 1,
         now() AT TIME ZONE 'utc' + make_interval(mins => $4::int), $5,
         '{}', 1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, status, "ops-hold-#{order_id}", minutes_from_now, released_at]
    )
  end

  defp insert_payment_attempt!(order_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         manual_review_reason, raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, 'ops-idem-secret', $3, $4, $5, 10000, 'ZAR', 1,
         'ops_payment_review', '{"secret":"raw-init"}', '{"secret":"raw-verify"}',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, "provider-ref-#{order_id}", @authorization_url, @access_code, status]
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

  defp insert_ticket_issue!(order_id, line_id, status, scanner_status) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, issued_at, revoked_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 987654, $3, $4, $5, $6, $7, now() AT TIME ZONE 'utc',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, line_id, @ticket_code, @qr_hash, @delivery_hash, status, scanner_status]
    )
  end

  defp insert_delivery_attempt!(order_id, ticket_issue_id, status) do
    Repo.query!(
      """
      INSERT INTO sales_delivery_attempts
        (sales_order_id, ticket_issue_id, channel, provider, recipient, status,
         template_name, attempt_number, provider_error_message, failure_reason,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 'whatsapp', 'meta', $3, $4, 'ticket_ready_af', 1,
         'raw provider message', 'fallback needed',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, ticket_issue_id, @raw_phone, status]
    )
  end

  defp insert_attendee_invalidation! do
    event_id = @event_id

    %{rows: [[attendee_id]]} =
      Repo.query!(
        """
        INSERT INTO attendees
          (event_id, ticket_code, first_name, last_name, email, ticket_type, payment_status,
           scan_eligibility, ineligibility_reason, inserted_at, updated_at)
        VALUES
          ($1, 'OPS-ATTENDEE', 'Ops', 'Attendee', $2, 'General', 'paid',
           'not_scannable', 'revoked', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id, @raw_email]
      )

    Repo.query!(
      """
      INSERT INTO attendee_invalidation_events
        (event_id, attendee_id, ticket_code, change_type, reason_code, effective_at, inserted_at)
      VALUES
        ($1, $2, 'OPS-ATTENDEE', 'not_scannable', 'revoked',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [event_id, attendee_id]
    )
  end

  defp insert_retryable_oban_job!(queue) do
    Repo.insert!(%Oban.Job{
      queue: queue,
      worker: "FastCheck.Workers.OpsTestWorker",
      args: %{},
      state: "retryable",
      attempt: 1,
      max_attempts: 20,
      scheduled_at: DateTime.utc_now()
    })
  end
end
