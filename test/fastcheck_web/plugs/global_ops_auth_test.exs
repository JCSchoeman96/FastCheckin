defmodule FastCheckWeb.Plugs.GlobalOpsAuthTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias FastCheckWeb.Plugs.GlobalOpsAuth
  alias Plug.Test, as: PlugTest

  setup do
    previous_access = Application.get_env(:fastcheck, :operations_global_access)
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{username: "admin", allowed_event_ids: []})
    Application.put_env(:fastcheck, :operations_global_access, allowed_usernames: ["admin"])

    on_exit(fn ->
      restore(:operations_global_access, previous_access)
      restore(:dashboard_auth, previous_auth)
    end)

    :ok
  end

  test "accepts a BrowserAuth-owned dashboard identity" do
    conn =
      PlugTest.conn(:get, "/dashboard/system/workers")
      |> PlugTest.init_test_session(%{
        dashboard_authenticated: true,
        dashboard_username: "admin"
      })
      |> assign(:current_user, %{username: "admin"})

    assert %{halted: false} = GlobalOpsAuth.call(conn, [])
  end

  test "denies authenticated users outside the global allowlist" do
    conn =
      PlugTest.conn(:get, "/dashboard/system/workers")
      |> PlugTest.init_test_session(%{
        dashboard_authenticated: true,
        dashboard_username: "operator"
      })
      |> assign(:current_user, %{username: "operator"})

    conn = GlobalOpsAuth.call(conn, [])
    assert conn.halted
    assert conn.status == 403
  end

  test "does not accept a spoofed actor map without the server session identity" do
    conn =
      PlugTest.conn(:get, "/dashboard/system/workers")
      |> assign(:current_user, %{username: "admin", allowed_event_ids: [123]})

    conn = GlobalOpsAuth.call(conn, [])
    assert conn.halted
    assert conn.status == 403
  end

  defp restore(key, nil), do: Application.delete_env(:fastcheck, key)
  defp restore(key, value), do: Application.put_env(:fastcheck, key, value)
end
