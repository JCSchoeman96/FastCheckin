defmodule FastCheckWeb.BrowserAuthTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheckWeb.Plugs.BrowserAuth

  @valid_username "admin"
  @valid_password "fastcheck"

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @valid_username,
      password: @valid_password
    })

    :ok
  end

  describe "dashboard routes" do
    @protected_paths [
      "/dashboard",
      "/scan/1",
      "/dashboard/occupancy/1",
      "/dashboard/sales",
      "/dashboard/sales/ops",
      "/dashboard/sales/audit/order/1",
      "/dashboard/sales/reviews",
      "/dashboard/sales/orders/1",
      "/dashboard/sales/tickets/1/pdf",
      "/dashboard/sales/checkout/1",
      "/dashboard/sales/internal-pilot/checkout/1",
      "/export/attendees/1",
      "/export/check-ins/1"
    ]

    test "all dashboard and operations routes require authentication", _context do
      for path <- @protected_paths do
        conn = get(build_conn(), path)

        assert redirected_to(conn) == "/login?redirect_to=#{URI.encode_www_form(path)}"
      end

      conn = delete(build_conn(), "/logout")
      assert redirected_to(conn) == "/login?redirect_to=%2Flogout"
    end

    test "redirect unauthenticated users to login", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert redirected_to(conn) == ~p"/login?redirect_to=%2F"
    end

    test "allow access with authenticated session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{
          dashboard_authenticated: true,
          dashboard_username: @valid_username
        })
        |> get(~p"/")

      assert html_response(conn, 200)
    end
  end

  describe "login" do
    test "creates session for valid credentials and redirects", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => @valid_username, "password" => @valid_password},
          "redirect_to" => "/dashboard"
        })

      assert get_session(conn, :dashboard_authenticated)
      assert get_session(conn, :dashboard_username) == @valid_username
      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "renders error on invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => @valid_username, "password" => "wrong"}
        })

      assert html_response(conn, 401)
      assert conn.resp_body =~ "Invalid credentials"
    end

    test "normalizes encoded redirect_to values", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => @valid_username, "password" => @valid_password},
          "redirect_to" => "%2F"
        })

      assert redirected_to(conn) == ~p"/"

      conn =
        post(build_conn(), ~p"/login", %{
          "session" => %{"username" => @valid_username, "password" => @valid_password},
          "redirect_to" => "%252Fdashboard"
        })

      assert redirected_to(conn) == ~p"/dashboard"
    end

    test "falls back to root for unsafe redirect_to values", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "session" => %{"username" => @valid_username, "password" => @valid_password},
          "redirect_to" => "%2F%2Fevil.com"
        })

      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "valid_admin_password?/1" do
    test "returns true for the configured dashboard password" do
      assert BrowserAuth.valid_admin_password?(@valid_password)
    end

    test "returns false for a wrong password" do
      refute BrowserAuth.valid_admin_password?("wrong-password")
    end

    test "returns false when length does not match configured password" do
      refute BrowserAuth.valid_admin_password?("x")
    end
  end
end
