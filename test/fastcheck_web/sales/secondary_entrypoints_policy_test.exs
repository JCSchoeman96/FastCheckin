defmodule FastCheckWeb.Sales.SecondaryEntrypointsPolicyTest do
  use FastCheckWeb.ConnCase, async: true

  test "unauthenticated user is redirected from admin checkout" do
    conn = get(build_conn(), ~p"/dashboard/sales/checkout/1")
    assert redirected_to(conn) == ~p"/login?redirect_to=%2Fdashboard%2Fsales%2Fcheckout%2F1"
  end

  test "unauthenticated user is redirected from internal pilot checkout" do
    conn = get(build_conn(), ~p"/dashboard/sales/internal-pilot/checkout/1")

    assert redirected_to(conn) ==
             ~p"/login?redirect_to=%2Fdashboard%2Fsales%2Finternal-pilot%2Fcheckout%2F1"
  end

  test "public web checkout route does not exist" do
    conn = get(build_conn(), "/events/1/checkout")
    assert conn.status == 404
  end
end
