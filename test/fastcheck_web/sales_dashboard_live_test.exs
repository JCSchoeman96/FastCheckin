defmodule FastCheckWeb.SalesDashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "dashboard.raw@example.com"
  @raw_phone "+27987654321"
  @raw_buyer_name "Dashboard Sensitive Buyer"
  @access_code "LIVE_ACCESS_SECRET"
  @authorization_url "https://checkout.paystack.test/pay/live-secret"
  @ticket_code "LIVE-TICKET-SECRET"
  @qr_hash "live-qr-hash"
  @delivery_hash "live-delivery-hash"
  @idempotency_key "live-idempotency-secret"

  test "unauthenticated user is redirected from sales dashboard" do
    conn = get(build_conn(), ~p"/dashboard/sales")

    assert redirected_to(conn) == ~p"/login?redirect_to=%2Fdashboard%2Fsales"
  end

  test "authenticated user sees empty sales dashboard", %{conn: conn} do
    {:ok, _view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales")

    assert html =~ "Sales dashboard"
    assert html =~ "Recent orders"
    assert html =~ "Manual review"
  end

  test "dashboard renders safe summaries and no destructive controls", %{conn: conn} do
    event = Fixtures.insert_event!()
    order_id = insert_dashboard_order!(event.id)

    {:ok, view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales")

    assert html =~ "FC-LIVE-ORDER"
    assert html =~ "Buyer"
    assert html =~ "d***@example.com"
    assert html =~ "***4321"
    refute_unsafe_html(html)
    refute_destructive_controls(html)

    selected = render_click(view, "select_order", %{"order-id" => to_string(order_id)})

    assert selected =~ "Order detail"
    assert selected =~ "Ticket issues"
    refute_unsafe_html(selected)
    refute_destructive_controls(selected)
  end

  test "filter submit ignores unknown keys and invalid selected order is safe", %{conn: conn} do
    event = Fixtures.insert_event!()
    _order_id = insert_dashboard_order!(event.id)

    {:ok, view, _html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales")

    filtered =
      render_submit(view, "apply_filters", %{
        "filters" => %{
          "event_id" => to_string(event.id),
          "search" => "FC-LIVE",
          "buyer_email" => @raw_email,
          "unknown" => "ignored"
        }
      })

    assert filtered =~ "FC-LIVE-ORDER"
    refute filtered =~ @raw_email

    not_found = render_click(view, "select_order", %{"order-id" => "999999999"})
    assert not_found =~ "Order not found"
  end

  defp refute_unsafe_html(html) do
    for unsafe <- [
          @raw_email,
          @raw_phone,
          @access_code,
          @authorization_url,
          @ticket_code,
          @qr_hash,
          @delivery_hash,
          @idempotency_key,
          "raw-payload"
        ] do
      refute html =~ unsafe
    end
  end

  defp refute_destructive_controls(html) do
    for forbidden <- [
          "refund",
          "revoke",
          "resend",
          "mark paid",
          "issue ticket",
          "release inventory",
          "resolve review"
        ] do
      refute String.downcase(html) =~ forbidden
    end
  end

  defp insert_dashboard_order!(event_id) do
    offer_id = insert_offer!(event_id)
    order_id = insert_order!(event_id)
    line_id = insert_order_line!(order_id, offer_id)
    insert_checkout_session!(order_id)
    insert_payment_attempt!(order_id)
    insert_payment_event!(order_id)
    insert_ticket_issue!(order_id, line_id)
    order_id
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
          ($1, 'Live offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
           1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id]
      )

    id
  end

  defp insert_order!(event_id) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, manual_review_reason,
           inserted_at, updated_at)
        VALUES
          ('FC-LIVE-ORDER', $1, $2, $3, $4, 'admin', 'manual_review',
           10000, 'ZAR', $5, 'payment_state_conflict', now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id, @raw_buyer_name, @raw_phone, @raw_email, @idempotency_key]
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
          ($1, $2, 1, 'General', 'Live offer', 'Live Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, offer_id]
      )

    id
  end

  defp insert_checkout_session!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, redis_hold_key, hold_token, hold_quantity, state_data,
         lock_version, inserted_at, updated_at)
      VALUES
        ($1, 'manual_review', $2, 'live-hold-token', 1, '{}', 1,
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, "live-hold-#{order_id}"]
    )
  end

  defp insert_payment_attempt!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         manual_review_reason, raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, $3, $4, $5, 'manual_review', 10000, 'ZAR', 1,
         'payment_state_conflict', '{"secret":"raw-init"}', '{"secret":"raw-verify"}',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, "provider-ref-#{order_id}", @idempotency_key, @authorization_url, @access_code]
    )
  end

  defp insert_payment_event!(order_id) do
    Repo.query!(
      """
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, signature_valid,
         payload_hash, raw_payload, received_at, processing_status, processing_attempt_count,
         inserted_at, updated_at)
      VALUES
        ('paystack', $1, $2, 'charge.success', true, $3, '{"secret":"raw-payload"}',
         now() AT TIME ZONE 'utc', 'manual_review', 1, now() AT TIME ZONE 'utc',
         now() AT TIME ZONE 'utc')
      """,
      [
        "evt-#{System.unique_integer([:positive])}",
        "provider-ref-#{order_id}",
        "payload-#{System.unique_integer([:positive])}"
      ]
    )
  end

  defp insert_ticket_issue!(order_id, line_id) do
    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, issued_at,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 111222, $3, $4, $5, 'manual_review', 'valid',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, line_id, @ticket_code, @qr_hash, @delivery_hash]
    )
  end
end
