defmodule FastCheckWeb.Sales.OpsDashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  @raw_email "ops.live@example.com"
  @raw_phone "+27821234567"
  @authorization_url "https://checkout.paystack.test/pay/live-ops-secret"
  @access_code "LIVE_OPS_ACCESS"

  test "unauthenticated user is redirected from ops dashboard" do
    conn = get(build_conn(), ~p"/dashboard/sales/ops")

    assert redirected_to(conn) == ~p"/login?redirect_to=%2Fdashboard%2Fsales%2Fops"
  end

  test "authenticated user sees safe operational dashboard", %{conn: conn} do
    event = Fixtures.insert_event!()
    insert_ops_order!(event.id)

    {:ok, _view, html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/ops")

    assert html =~ "Sales operations"
    assert html =~ "Payment health"
    assert html =~ "Manual review"
    assert html =~ "Worker backlog"
    refute_unsafe_html(html)
    refute String.downcase(html) =~ "mark paid"
    refute String.downcase(html) =~ "issue ticket"
  end

  defp refute_unsafe_html(html) do
    for unsafe <- [@raw_email, @raw_phone, @authorization_url, @access_code, "raw-payload"] do
      refute html =~ unsafe
    end
  end

  defp insert_ops_order!(event_id) do
    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, manual_review_reason, inserted_at, updated_at)
        VALUES
          ('FC-LIVE-OPS', $1, 'Live Ops Buyer', $2, $3, 'admin', 'manual_review',
           10000, 'ZAR', 'ops_live_review', now() AT TIME ZONE 'utc',
           now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [event_id, @raw_phone, @raw_email]
      )

    Repo.query!(
      """
      INSERT INTO sales_payment_attempts
        (sales_order_id, provider, provider_reference, idempotency_key, authorization_url,
         access_code, status, amount_cents, currency, verification_attempt_count,
         raw_initialize_response, raw_verify_response, inserted_at, updated_at)
      VALUES
        ($1, 'paystack', $2, 'live-ops-idem', $3, $4, 'failed', 10000, 'ZAR', 1,
         '{"secret":"raw-init"}', '{"secret":"raw-verify"}',
         now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
      """,
      [order_id, "provider-ref-live-#{order_id}", @authorization_url, @access_code]
    )
  end
end
