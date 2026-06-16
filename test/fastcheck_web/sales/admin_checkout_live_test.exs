defmodule FastCheckWeb.Sales.AdminCheckoutLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.Order
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  setup do
    event = Fixtures.insert_event!()
    {offer, cleanup} = Fixtures.insert_admin_offer!(event.id)
    on_exit(cleanup)
    {:ok, event: event, offer: offer}
  end

  defp mount_admin_checkout(conn, event_id) do
    conn
    |> Fixtures.authenticated_conn()
    |> live(~p"/dashboard/sales/checkout/#{event_id}")
  end

  test "authenticated admin checkout renders offers", %{conn: conn, event: event, offer: offer} do
    assert {:ok, view, html} = mount_admin_checkout(conn, event.id)
    assert html =~ "Admin-assisted checkout"
    assert html =~ offer.name
    assert has_element?(view, "#admin-checkout-form")
  end

  test "admin checkout starts checkout through secondary entrypoints", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    assert {:ok, view, _html} = mount_admin_checkout(conn, event.id)

    view
    |> form("#admin-checkout-form", %{
      "checkout" => %{
        "ticket_offer_id" => to_string(offer.id),
        "quantity" => "1",
        "buyer_name" => "Buyer One"
      }
    })
    |> render_submit()

    assert render(view) =~ "Checkout started"

    order =
      Order
      |> Query.filter(event_id == ^event.id and source_channel == "admin")
      |> Ash.read_one!(authorize?: false)

    assert order.status == "awaiting_payment"
  end

  test "failed checkout keeps the same idempotency key assign", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    assert {:ok, view, _html} = mount_admin_checkout(conn, event.id)
    key_before = idempotency_key(view)

    view
    |> form("#admin-checkout-form", %{
      "checkout" => %{
        "ticket_offer_id" => to_string(offer.id),
        "quantity" => "0"
      }
    })
    |> render_submit()

    assert idempotency_key(view) == key_before
  end

  test "invalid event_id redirects safely without 500", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
             mount_admin_checkout(conn, 99_999_999)
  end

  defp idempotency_key(view) do
    :sys.get_state(view.pid).socket.assigns.idempotency_key
  end
end
