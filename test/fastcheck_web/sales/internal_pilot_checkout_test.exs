defmodule FastCheckWeb.Sales.InternalPilotCheckoutTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  setup do
    previous = Application.get_env(:fastcheck, :sales_internal_pilot_enabled)
    Application.put_env(:fastcheck, :sales_internal_pilot_enabled, true)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:fastcheck, :sales_internal_pilot_enabled)
      else
        Application.put_env(:fastcheck, :sales_internal_pilot_enabled, previous)
      end
    end)

    event = Fixtures.insert_event!()
    {offer, cleanup} = Fixtures.insert_internal_offer!(event.id)
    on_exit(cleanup)
    {:ok, event: event, offer: offer}
  end

  defp mount_pilot_checkout(conn, event_id) do
    conn
    |> Fixtures.authenticated_conn()
    |> live(~p"/dashboard/sales/internal-pilot/checkout/#{event_id}")
  end

  test "internal pilot checkout is not public", %{conn: conn, event: event} do
    conn = get(conn, ~p"/dashboard/sales/internal-pilot/checkout/#{event.id}")
    assert redirected_to(conn) =~ "/login"
  end

  test "internal pilot checkout renders when enabled", %{conn: conn, event: event, offer: offer} do
    assert {:ok, _view, html} = mount_pilot_checkout(conn, event.id)
    assert html =~ "Internal pilot only"
    assert html =~ offer.name
  end

  test "internal pilot checkout redirects when disabled", %{conn: conn, event: event} do
    Application.put_env(:fastcheck, :sales_internal_pilot_enabled, false)

    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             mount_pilot_checkout(conn, event.id)
  end
end
