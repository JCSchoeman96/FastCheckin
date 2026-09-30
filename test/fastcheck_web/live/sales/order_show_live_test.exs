defmodule FastCheckWeb.Sales.OrderShowLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias FastCheck.Repo
  alias FastCheck.Sales.AdminRefundFixtures, as: Fixtures
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  @raw_email "order.show@example.com"
  @raw_phone "+27911112222"
  @access_code "ORDER_SHOW_ACCESS"
  @authorization_url "https://checkout.paystack.test/pay/order-show-secret"
  @ticket_code "ORDER-SHOW-TICKET"
  @qr_hash "order-show-qr-hash"
  @delivery_hash "order-show-delivery-hash"

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: WebFixtures.dashboard_username(),
      password: Fixtures.dashboard_password()
    })

    :ok
  end

  test "unauthenticated user is redirected from order show" do
    conn = get(build_conn(), ~p"/dashboard/sales/orders/1")
    assert redirected_to(conn) =~ "/login"
  end

  test "authenticated user sees masked order context without sensitive values" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    {:ok, _view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    assert html =~ "Sales order operations"
    assert html =~ "Issued tickets"
    assert html =~ "***"
    refute_unsafe_html(html)
  end

  test "issued ticket rows include safe PDF download links" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    {:ok, _view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    assert html =~ "Download PDF"
    assert html =~ ~s(href="/dashboard/sales/tickets/#{ticket_issue_id}/pdf")
    assert html =~ "***"
    refute_unsafe_html(html)
  end

  test "revoked and non-issued ticket rows do not show PDF download links" do
    %{order_id: revoked_order_id, ticket_issue_ids: [revoked_ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET status = 'revoked' WHERE id = $1", [
      revoked_ticket_issue_id
    ])

    {:ok, _view, revoked_html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{revoked_order_id}")

    refute revoked_html =~ "Download PDF"
    refute revoked_html =~ ~s(/dashboard/sales/tickets/#{revoked_ticket_issue_id}/pdf)
    refute_unsafe_html(revoked_html)

    %{order_id: pending_order_id, ticket_issue_ids: [pending_ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET status = 'pending' WHERE id = $1", [
      pending_ticket_issue_id
    ])

    {:ok, _view, pending_html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{pending_order_id}")

    refute pending_html =~ "Download PDF"
    refute pending_html =~ ~s(/dashboard/sales/tickets/#{pending_ticket_issue_id}/pdf)
    refute_unsafe_html(pending_html)
  end

  test "scanner-revoked issued ticket rows do not show PDF download links" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET scanner_status = 'revoked' WHERE id = $1", [
      ticket_issue_id
    ])

    {:ok, _view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    refute html =~ "Download PDF"
    refute html =~ ~s(/dashboard/sales/tickets/#{ticket_issue_id}/pdf)
    refute_unsafe_html(html)
  end

  test "authenticated user sees safe delivery attempt summary" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!(
      """
      INSERT INTO sales_delivery_attempts
        (sales_order_id, ticket_issue_id, channel, provider, recipient, status, template_name,
         within_whatsapp_window, provider_message_id, attempt_number, provider_error_code,
         provider_error_message, failure_reason, fallback_channel, sent_at, inserted_at, updated_at)
      VALUES
        ($1, $2, 'whatsapp', 'meta', $3, 'manual_review', 'fastcheck_ticket_ready_af',
         false, 'wamid.safe-summary', 1, '190', $4, 'auth_error', 'manual_review',
         now(), now(), now())
      """,
      [
        order_id,
        ticket_issue_id,
        @raw_phone,
        "raw provider payload #{@authorization_url} #{@delivery_hash}"
      ]
    )

    {:ok, _view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    assert html =~ "Delivery attempts"
    assert html =~ "manual review"
    assert html =~ "fastcheck_ticket_ready_af"
    assert html =~ "outside window"
    refute_unsafe_html(html)
    refute html =~ "raw provider payload"
    refute html =~ "wamid.safe-summary"
  end

  test "authenticated user can revoke a ticket through AdminRevocations boundary" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    {:ok, view, _html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    html =
      render_submit(view, "revoke_ticket", %{
        "admin_action" => %{
          "ticket_issue_id" => to_string(ticket_issue_id),
          "reason" => "Fraud investigation",
          "idempotency_key" => "lv-revoke-1"
        }
      })

    assert html =~ "Action completed" || html =~ "Fraud investigation"

    assert Repo.one!(
             from t in "sales_ticket_issues", where: t.id == ^ticket_issue_id, select: t.status
           ) ==
             "revoked"
  end

  test "mark refunded requires admin password" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    {:ok, view, _html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    html =
      render_submit(view, "mark_refunded", %{
        "admin_action" => %{
          "reason" => "External refund processed",
          "admin_password" => Fixtures.dashboard_password(),
          "provider_status" => "processed",
          "provider_refund_reference" => "LV-RRN-#{System.unique_integer([:positive])}",
          "provider_refunded_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "amount_cents" => "12500",
          "currency" => "ZAR",
          "idempotency_key" => "lv-refund-1"
        }
      })

    assert html =~ "Action completed" || html =~ "External refund"
    assert Fixtures.order_status(order_id) == "refunded"
  end

  test "refund form collects processed Paystack evidence and full-order amount" do
    %{order_id: order_id} = Fixtures.issued_order_fixture()

    {:ok, _view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    assert html =~ "I confirm Paystack shows this refund as processed."
    assert html =~ ~s(name="admin_action[provider_refund_reference]")
    assert html =~ ~s(name="admin_action[provider_refunded_at]")
    assert html =~ ~s(name="admin_action[amount_cents]" value="12500")
    assert html =~ ~s(name="admin_action[currency]" value="ZAR")
    assert html =~ "Full-order refunds only"
  end

  test "admin can retry refund inventory from manual review" do
    fixture = Fixtures.inventory_pending_refund_fixture()

    Repo.query!(
      "UPDATE sales_refunds SET status = 'inventory_manual_review', manual_review_reason = 'review' WHERE id = $1",
      [fixture.refund_id]
    )

    {:ok, view, html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{fixture.order_id}")

    assert html =~ "Retry refund inventory resolution"

    html =
      render_submit(view, "retry_refund_inventory", %{
        "admin_action" => %{
          "reason" => "Confirmed the original refund record",
          "admin_password" => Fixtures.dashboard_password()
        }
      })

    assert html =~ "Action completed successfully."

    assert Repo.one!(
             from refund in "sales_refunds",
               where: refund.id == ^fixture.refund_id,
               select: refund.status
           ) == "inventory_pending"
  end

  test "order revoke failure surfaces blocking error instead of success" do
    %{order_id: order_id, ticket_issue_ids: [ticket_issue_id | _]} =
      Fixtures.issued_order_fixture()

    Repo.query!("UPDATE sales_ticket_issues SET attendee_id = $1 WHERE id = $2", [
      9_999_999,
      ticket_issue_id
    ])

    {:ok, view, _html} =
      build_conn()
      |> WebFixtures.authenticated_conn()
      |> live(~p"/dashboard/sales/orders/#{order_id}")

    html =
      render_submit(view, "revoke_order_tickets", %{
        "admin_action" => %{
          "reason" => "Broken attendee link",
          "confirmed_bulk" => "true",
          "admin_password" => Fixtures.dashboard_password(),
          "idempotency_key" => "lv-revoke-order-fail"
        }
      })

    assert html =~ "Could not revoke"
    refute html =~ "Action completed successfully."
  end

  defp refute_unsafe_html(html) do
    refute html =~ @raw_email
    refute html =~ @raw_phone
    refute html =~ @access_code
    refute html =~ @authorization_url
    refute html =~ @ticket_code
    refute html =~ @qr_hash
    refute html =~ @delivery_hash
    refute html =~ "raw-init"
    refute html =~ "raw-verify"
  end
end
