defmodule FastCheckWeb.Operations.WorkersDashboardLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheck.Operations.ObanSnapshot.Store
  alias Plug.Test, as: PlugTest

  setup do
    previous_access = Application.get_env(:fastcheck, :operations_global_access)
    Application.put_env(:fastcheck, :operations_global_access, allowed_usernames: ["admin"])

    on_exit(fn ->
      if is_nil(previous_access),
        do: Application.delete_env(:fastcheck, :operations_global_access),
        else: Application.put_env(:fastcheck, :operations_global_access, previous_access)
    end)

    :ok
  end

  test "unauthenticated users are redirected" do
    conn = get(build_conn(), ~p"/dashboard/system/workers")
    assert redirected_to(conn) == ~p"/login?redirect_to=%2Fdashboard%2Fsystem%2Fworkers"
  end

  test "global admin sees read-only worker health without an Event selector", %{conn: conn} do
    conn =
      PlugTest.init_test_session(conn, %{
        dashboard_authenticated: true,
        dashboard_username: "admin"
      })

    {:ok, _view, html} = live(conn, ~p"/dashboard/system/workers")

    assert html =~ "Global system worker health"
    assert html =~ "Unexpected queues"
    refute html =~ "Event ID"
    refute html =~ "Retry job"
    refute html =~ "Pause queue"
    refute html =~ "Delete job"
  end

  test "authenticated event grant alone cannot open the global page", %{conn: conn} do
    Application.put_env(:fastcheck, :operations_global_access, allowed_usernames: ["ops"])

    conn =
      PlugTest.init_test_session(conn, %{
        dashboard_authenticated: true,
        dashboard_username: "admin"
      })

    conn = get(conn, ~p"/dashboard/system/workers")
    assert response(conn, 403) == "Forbidden"
  end

  test "refreshes distribution status after a mirror failure", %{conn: conn} do
    assert :ok = Store.set_distribution_mode("unavailable")
    on_exit(fn -> Store.set_distribution_mode("unavailable") end)

    conn =
      PlugTest.init_test_session(conn, %{
        dashboard_authenticated: true,
        dashboard_username: "admin"
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/system/workers")
    assert :ok = Store.set_distribution_mode("shared_mirror_degraded")
    assert render(view) =~ "shared_mirror_degraded"
  end
end
