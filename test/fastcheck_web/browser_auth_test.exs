defmodule FastCheckWeb.BrowserAuthTest do
  use FastCheckWeb.ConnCase, async: true

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
  end
end
