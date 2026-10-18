defmodule FastCheckWeb.BrowserAuthTest do
  use FastCheckWeb.ConnCase, async: false

  alias FastCheck.Repo
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

    test "valid authenticated session revalidation does not query durable Event grants" do
      conn =
        build_conn()
        |> init_test_session(%{
          dashboard_authenticated: true,
          dashboard_username: @valid_username
        })

      {conn, grant_query_count} =
        capture_dashboard_grant_queries(fn -> BrowserAuth.call(conn, []) end)

      refute conn.halted
      assert conn.assigns.current_user == %{id: @valid_username, username: @valid_username}
      assert grant_query_count == 0
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

  defp capture_dashboard_grant_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "browser-auth-grants-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, metadata, _config ->
        query = metadata.query

        if String.contains?(String.downcase(query), "dashboard_event_grants") do
          send(parent, {:dashboard_grant_query, ref})
        end
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_dashboard_grant_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_dashboard_grant_queries(ref, count) do
    receive do
      {:dashboard_grant_query, ^ref} -> drain_dashboard_grant_queries(ref, count + 1)
    after
      0 -> count
    end
  end
end
