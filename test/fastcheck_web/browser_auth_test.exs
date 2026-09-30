defmodule FastCheckWeb.BrowserAuthTest do
  use FastCheckWeb.ConnCase, async: false

  alias FastCheckWeb.Plugs.BrowserAuth

  @valid_username "admin"
  @valid_password "fastcheck"

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @valid_username,
      password: @valid_password
    })

    on_exit(fn ->
      if is_nil(previous_auth) do
        Application.delete_env(:fastcheck, :dashboard_auth)
      else
        Application.put_env(:fastcheck, :dashboard_auth, previous_auth)
      end
    end)

    :ok
  end

  describe "dashboard routes" do
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

    test "rejects an authenticated session whose username no longer matches configuration", %{
      conn: conn
    } do
      conn =
        conn
        |> init_test_session(%{
          dashboard_authenticated: true,
          dashboard_username: "former-admin"
        })
        |> get(~p"/")

      assert redirected_to(conn) == ~p"/login?redirect_to=%2F"
    end

    test "rejects an authenticated session without a dashboard identity", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{dashboard_authenticated: true})
        |> get(~p"/")

      assert redirected_to(conn) == ~p"/login?redirect_to=%2F"
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
