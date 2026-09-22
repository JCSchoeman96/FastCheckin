defmodule FastCheckWeb.Sales.WhatsAppOfferLiveTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Events
  alias FastCheck.Repo
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

  test "authenticated admin sees event WhatsApp order limit with helper copy", %{
    conn: conn,
    event: event
  } do
    assert {:ok, _view, html} = mount_offers(conn, event.id)

    assert html =~ "Event max tickets per WhatsApp order"
    assert html =~ "effective customer limit is the lower"
    assert html =~ "Event 4 + Offer 6"
    assert html =~ "Event 6 + Offer 2"
    assert html =~ ~s|value="9"| or html =~ "9"
  end

  test "admin can change event cap from 9 to 12", %{conn: conn, event: event} do
    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#event-quantity-cap-form", %{
      "event_quantity_cap" => %{"whatsapp_max_tickets_per_order" => "12"}
    })
    |> render_submit()

    assert render(view) =~ "Event WhatsApp order limit updated."
    assert Events.whatsapp_max_tickets_per_order(event.id) == 12
  end

  test "admin can change event cap from 9 to 3", %{conn: conn, event: event} do
    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#event-quantity-cap-form", %{
      "event_quantity_cap" => %{"whatsapp_max_tickets_per_order" => "3"}
    })
    |> render_submit()

    assert render(view) =~ "Event WhatsApp order limit updated."
    assert Events.whatsapp_max_tickets_per_order(event.id) == 3
  end

  test "invalid event cap 0 is rejected in admin UI", %{conn: conn, event: event} do
    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#event-quantity-cap-form", %{
      "event_quantity_cap" => %{"whatsapp_max_tickets_per_order" => "0"}
    })
    |> render_submit()

    assert render(view) =~ "positive whole number"
    assert Events.whatsapp_max_tickets_per_order(event.id) == 9
  end

  test "forms do not advertise a temporary 1-9 quantity ceiling", %{conn: conn, event: event} do
    assert {:ok, _view, html} = mount_offers(conn, event.id)

    refute html =~ "(1-9)"
    refute html =~ ~s|max="9"|
  end

  test "create form accepts double-digit max per order within inventory", %{
    conn: conn,
    event: event
  } do
    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#whatsapp-offer-create-form", %{
      "offer_create" => %{
        "name" => "Double Digit Max",
        "price" => "100",
        "regular_price" => "",
        "initial_quantity" => "20",
        "max_per_order" => "12"
      }
    })
    |> render_submit()

    html = render(view)
    assert html =~ "Double Digit Max"

    offer =
      Repo.one!(
        from(o in "sales_ticket_offers",
          where: o.event_id == ^event.id and o.name == "Double Digit Max",
          select: map(o, [:id, :max_per_order, :configured_quantity_available])
        )
      )

    assert offer.max_per_order == 12
    assert offer.configured_quantity_available == 20
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer[:id]) end)
  end

  test "edit form persists double-digit max per order when inventory allows", %{
    conn: conn,
    event: event
  } do
    offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "Raise Max",
        configured_quantity_available: 20,
        initial_quantity: 20,
        max_per_order: 2
      )

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#offer-form-#{offer.id}", %{
      "offer" => %{
        "name" => "Raise Max",
        "price" => "100",
        "regular_price" => "",
        "max_per_order" => "12",
        "lock_version" => to_string(offer.lock_version)
      },
      "offer_id" => to_string(offer.id)
    })
    |> render_submit()

    reloaded =
      TicketOffer
      |> Ash.Query.for_read(:get_by_id, %{id: offer.id})
      |> Ash.read_one!(authorize?: false)

    assert reloaded.max_per_order == 12
    assert render(view) =~ "Raise Max"
  end

  test "archived event shows event cap read-only", %{conn: conn, event: event} do
    assert {:ok, _} = Events.set_whatsapp_max_tickets_per_order(event.id, 4)
    assert {:ok, _} = Events.archive_event(event.id)

    assert {:ok, _view, html} = mount_offers(conn, event.id)
    assert html =~ "Current limit"
    assert html =~ "4"
    refute html =~ "event-quantity-cap-form"
  end

  test "changing event cap does not alter ticket offer max_per_order", %{conn: conn, event: event} do
    offer =
      SalesFixtures.insert_offer!(
        event_id: event.id,
        name: "Cap Isolation",
        max_per_order: 5
      )

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)

    assert {:ok, view, _html} = mount_offers(conn, event.id)

    view
    |> form("#event-quantity-cap-form", %{
      "event_quantity_cap" => %{"whatsapp_max_tickets_per_order" => "2"}
    })
    |> render_submit()

    reloaded =
      TicketOffer
      |> Ash.Query.for_read(:get_by_id, %{id: offer.id})
      |> Ash.read_one!(authorize?: false)

    assert reloaded.max_per_order == 5
  end

  test "dashboard contains manage whatsapp tickets link", %{conn: conn, event: event} do
    {:ok, view, _html} =
      conn
      |> Fixtures.authenticated_conn()
      |> live(~p"/dashboard")

    assert has_element?(view, "#manage-whatsapp-offers-#{event.id}", "Manage WhatsApp tickets")
  end

  test "inventory initialization failure still shows persisted disabled offer", %{
    conn: conn,
    event: event
  } do
    SalesFixtures.with_redis_stopped(fn ->
      assert {:ok, view, _html} = mount_offers(conn, event.id)

      view
      |> form("#whatsapp-offer-create-form", %{
        "offer_create" => %{
          "name" => "Partial Create Offer",
          "price" => "88",
          "regular_price" => "",
          "initial_quantity" => "5",
          "max_per_order" => "1"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Partial Create Offer"
      assert html =~ "Retry inventory setup"
      assert html =~ "live inventory could not be initialized"
    end)
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
