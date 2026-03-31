defmodule FastCheckWeb.Plugs.SecurityHeadersTest do
  use FastCheckWeb.ConnCase, async: true

  alias FastCheckWeb.Plugs.SecurityHeaders

  @valid_username "admin"

  setup do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @valid_username,
      password: "fastcheck"
    })

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
