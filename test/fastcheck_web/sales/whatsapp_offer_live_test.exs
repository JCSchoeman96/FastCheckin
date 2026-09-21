defmodule FastCheckWeb.Sales.WhatsAppOfferLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ash.Changeset
  alias FastCheck.Events
  alias FastCheck.Sales.TicketOffer
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheckWeb.SalesWebFixtures, as: Fixtures

  setup do
    event = Fixtures.insert_event!()
    {:ok, event: event}
  end

  defp mount_offers(conn, event_id) do
    conn
    |> Fixtures.authenticated_conn()
    |> live(~p"/dashboard/events/#{event_id}/whatsapp-offers")
  end

  test "authenticated admin can view and create whatsapp offers", %{conn: conn, event: event} do
    assert {:ok, view, html} = mount_offers(conn, event.id)
    assert html =~ "Manage WhatsApp tickets"
    assert html =~ "Event WhatsApp Sales gate"

    view
    |> form("#whatsapp-offer-create-form", %{
      "offer_create" => %{
        "name" => "WhatsApp GA",
        "price" => "120",
        "regular_price" => "150",
        "initial_quantity" => "20",
        "max_per_order" => "2"
      }
    })
    |> render_submit()

    assert render(view) =~ "WhatsApp GA"
    assert render(view) =~ "R 120"
    assert render(view) =~ "R 150"
  end

  test "unauthenticated users are redirected", %{conn: conn, event: event} do
    assert {:error, {:redirect, %{to: redirect_to}}} =
             live(conn, ~p"/dashboard/events/#{event.id}/whatsapp-offers")

    assert redirect_to =~ "/login"
  end

  test "invalid event redirects safely", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/dashboard"}}} = mount_offers(conn, 99_999_999)
  end

  test "archived event is read-only", %{conn: conn, event: event} do
    assert {:ok, _event} = Events.archive_event(event.id)

    assert {:ok, view, html} = mount_offers(conn, event.id)
    assert html =~ "read-only"
    refute has_element?(view, "#whatsapp-offer-create-form")
  end

  test "all-channel offer is displayed without changing its channel", %{conn: conn, event: event} do
    offer =
      SalesFixtures.insert_offer!(event_id: event.id, sales_channel: "all", name: "All Channel")

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert {:ok, view, html} = mount_offers(conn, event.id)
    assert html =~ "All Channel"
    assert html =~ "Channel: all"

    view
    |> form("#offer-form-#{offer.id}", %{
      "offer" => %{
        "name" => "All Channel Updated",
        "price" => "90",
        "regular_price" => "",
        "max_per_order" => "1",
        "lock_version" => to_string(offer.lock_version)
      },
      "offer_id" => to_string(offer.id)
    })
    |> render_submit()

    reloaded =
      TicketOffer
      |> Ash.Query.for_read(:get_by_id, %{id: offer.id})
      |> Ash.read_one!(authorize?: false)

    assert reloaded.sales_channel == "all"
    assert reloaded.name == "All Channel Updated"
  end

  test "dashboard contains manage whatsapp tickets link", %{conn: conn, event: event} do
    {:ok, view, _html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard")

    assert has_element?(view, "#manage-whatsapp-offers-#{event.id}", "Manage WhatsApp tickets")
  end

  test "stale optimistic lock conflict reloads safely", %{conn: conn, event: event} do
    offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "Stale Offer",
        sales_enabled: false
      )

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert {:ok, view, _html} = mount_offers(conn, event.id)

    offer
    |> Changeset.for_update(
      :update_offer,
      %{name: "Changed Elsewhere"},
      actor: SalesFixtures.admin_actor([event.id])
    )
    |> Ash.update!(authorize?: true)

    view
    |> form("#offer-form-#{offer.id}", %{
      "offer" => %{
        "name" => "Stale Edit",
        "price" => "100",
        "regular_price" => "",
        "max_per_order" => "1",
        "lock_version" => to_string(offer.lock_version)
      },
      "offer_id" => to_string(offer.id)
    })
    |> render_submit()

    assert render(view) =~ "changed elsewhere"
    assert render(view) =~ "Changed Elsewhere"
  end
end
