defmodule FastCheckWeb.SalesManualReviewLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "manual.live@example.com"
  @raw_phone "+27987654321"
  @access_code "LIVE_ACCESS_SECRET"
  @authorization_url "https://checkout.paystack.test/pay/manual-review-secret"
  @ticket_code "LIVE-TICKET-SECRET"
  @qr_hash "live-qr-hash"
  @delivery_hash "live-delivery-hash"

  test "unauthenticated user is redirected from manual review operations" do
    conn = get(build_conn(), ~p"/dashboard/sales/reviews")

    assert redirected_to(conn) == ~p"/login?redirect_to=%2Fdashboard%2Fsales%2Freviews"
  end

  test "authenticated user sees safe manual review queue and no forbidden controls", %{conn: conn} do
    order_id = insert_review_case!()

    {:ok, view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/reviews")

    assert html =~ "Manual review operations"
    assert html =~ "MR-LIVE"
    assert html =~ "m***@example.com"
    assert html =~ "***4321"
    refute_unsafe_html(html)
    refute_forbidden_controls(html)

    detail =
      render_click(view, "select_subject", %{
        "subject-type" => "order",
        "subject-id" => to_string(order_id)
      })

    assert detail =~ "Review detail"
    refute_unsafe_html(detail)
    refute_forbidden_controls(detail)
  end

  test "LiveView source calls ManualReview service only for writes" do
    source = File.read!("lib/fastcheck_web/live/sales_manual_review_live.ex")

    assert source =~ "FastCheck.Sales.ManualReview"
    refute source =~ "Ash.Changeset"
    refute source =~ "Ash.update"
    refute source =~ "Ash.create"
    refute source =~ "Repo.update"
    refute source =~ "Repo.update_all"
    refute source =~ "Oban.insert"
    refute source =~ "Issuer.issue_order"
    refute source =~ "VerifyPaymentWorker.new"
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
          "raw-payload",
          "raw-verify",
          "raw-init"
        ] do
      refute html =~ unsafe
    end
  end

  defp refute_forbidden_controls(html) do
    downcased = String.downcase(html)

    for forbidden <- ["mark paid", "issue ticket", "refund", "revoke", "resend", "delivery"] do
      refute downcased =~ forbidden
    end
  end

  defp insert_review_case! do
    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, manual_review_reason, lock_version,
           inserted_at, updated_at)
        VALUES
          ('MR-LIVE', 91002, 'Manual Live Buyer', $1, $2, 'admin', 'manual_review',
           10000, 'ZAR', 'payment_state_conflict', 1, now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [@raw_phone, @raw_email]
      )

    %{rows: [[line_id]]} =
      Repo.query!("""
      INSERT INTO sales_ticket_offers
        (event_id, name, ticket_type, price_cents, currency, configured_quantity_available,
         initial_quantity, max_per_order, sales_enabled, sales_channel, starts_at, ends_at,
         lock_version, inserted_at, updated_at)
      VALUES
        (91002, 'Manual Offer', 'General', 10000, 'ZAR', 100, 100, 4, true, 'admin',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc' + interval '30 days',
         1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      RETURNING id
      """)

    %{rows: [[order_line_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_order_lines
          (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
           event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
           metadata, inserted_at, updated_at)
        VALUES
          ($1, $2, 1, 'General', 'Manual Offer', 'Manual Event', 1, 10000, 10000,
           'ZAR', '{}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [order_id, line_id]
      )

    Repo.query!(
      """
      INSERT INTO sales_checkout_sessions
        (sales_order_id, status, hold_quantity, state_data, lock_version, inserted_at, updated_at)
      VALUES ($1, 'manual_review', 1, '{}', 1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id]
    )

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         manual_review_reason, raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, 'live-idem-secret', $3, $4, 'manual_review', 10000,
         'ZAR', 1, 'payment_state_conflict', '{"secret":"raw-init"}',
         '{"secret":"raw-verify"}', now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, "provider-ref-#{order_id}", @authorization_url, @access_code]
    )

    Repo.query!(
      """
      INSERT INTO sales_ticket_issues
        (sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code,
         qr_token_hash, delivery_token_hash, status, scanner_status, inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 123456, $3, $4, $5, 'manual_review', 'valid',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, order_line_id, @ticket_code, @qr_hash, @delivery_hash]
    )

    order_id
  end
end
