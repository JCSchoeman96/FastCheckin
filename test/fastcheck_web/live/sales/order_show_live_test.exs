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
          "idempotency_key" => "lv-refund-1"
        }
      })

    assert html =~ "Action completed" || html =~ "External refund"
    assert Fixtures.order_status(order_id) == "refunded"
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
