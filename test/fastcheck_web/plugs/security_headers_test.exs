defmodule FastCheckWeb.Plugs.SecurityHeadersTest do
  use FastCheckWeb.ConnCase, async: false

  alias FastCheckWeb.Plugs.SecurityHeaders

  @valid_username "admin"

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @valid_username,
      password: "fastcheck"
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

  test "browser responses include the shared content security policy", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        dashboard_authenticated: true,
        dashboard_username: @valid_username
      })
      |> get(~p"/")

    assert html_response(conn, 200)

    assert get_resp_header(conn, "content-security-policy") == [
             SecurityHeaders.browser_secure_headers()["content-security-policy"]
           ]
  end
end
