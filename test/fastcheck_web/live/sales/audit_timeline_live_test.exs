defmodule FastCheckWeb.Sales.AuditTimelineLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "audit.live@example.com"
  @raw_phone "+27827654321"
  @authorization_url "https://checkout.paystack.test/pay/live-audit-secret"
  @idempotency_key "live-audit-idem-secret"

  test "unauthenticated user is redirected from audit timeline" do
    conn = get(build_conn(), ~p"/dashboard/sales/audit/order/123")

    assert redirected_to(conn) ==
             ~p"/login?redirect_to=%2Fdashboard%2Fsales%2Faudit%2Forder%2F123"
  end

  test "authenticated user sees redacted audit timeline", %{conn: conn} do
    _event = Fixtures.insert_event!()
    order_id = insert_order_with_transition!()

    {:ok, _view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/audit/order/#{order_id}")

    assert html =~ "Audit timeline"
    assert html =~ "manual review"
    refute html =~ @raw_email
    refute html =~ @raw_phone
    refute html =~ @authorization_url
    refute html =~ @idempotency_key
    refute html =~ "raw-payload"
  end

  defp insert_order_with_transition! do
    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, idempotency_key, manual_review_reason,
           inserted_at, updated_at)
        VALUES
          ('FC-LIVE-AUDIT', 21023, 'Live Audit Buyer', $1, $2, 'admin',
           'manual_review', 10000, 'ZAR', $3, 'audit_live_review',
           now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [@raw_phone, @raw_email, @idempotency_key]
      )

    Repo.query!(
      """
      INSERT INTO sales_state_transitions
        (entity_type, entity_id, from_state, to_state, reason, actor_type, actor_id,
         metadata, correlation_id, request_id, idempotency_key, source, inserted_at)
      VALUES
        ('Order', $1, 'paid_verified', 'manual_review', 'manual review', 'admin', $2,
         $3, 'corr-live-audit', 'req-live-audit', $4, 'audit_live',
         now() AT TIME ZONE 'utc')
      """,
      [
        Integer.to_string(order_id),
        @raw_email,
        Jason.encode!(%{
          buyer_phone: @raw_phone,
          authorization_url: @authorization_url,
          raw_payload: %{"secret" => "raw-payload"}
        }),
        @idempotency_key
      ]
    )

    order_id
  end
end
