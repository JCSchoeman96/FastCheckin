defmodule FastCheck.Sales.OfferManagementTest do
  use FastCheck.DataCase, async: false

  require Ash.Query
  require Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.OfferManagement
  alias FastCheck.Sales.TicketOffer
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheckWeb.SalesWebFixtures

  setup do
    event = SalesWebFixtures.insert_event!(%{name: "Offer Management Event"})
    actor = OfferManagement.admin_actor_from_user(%{username: "admin"}, event.id)
    {:ok, event: event, actor: actor}
  end

  test "create_offer creates disabled offer, initializes redis, and optionally enables", %{
    event: event,
    actor: actor
  } do
    assert {:ok, offer} =
             OfferManagement.create_offer(actor, event.id, %{
               "name" => "General Admission",
               "price" => "100",
               "initial_quantity" => "25",
               "max_per_order" => "2",
               "sales_enabled" => "true"
             })

    assert offer.sales_enabled
    assert offer.sales_channel == "whatsapp"
    assert offer.currency == "ZAR"
    assert offer.configured_quantity_available == 25

    assert {:ok, %{configured_quantity: 25, ledger_state: :healthy}} =
             ReservationLedger.get_availability(offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "create_offer without enable request stays disabled even after inventory init", %{
    event: event,
    actor: actor
  } do
    assert {:ok, offer} =
             OfferManagement.create_offer(actor, event.id, %{
               "name" => "Disabled Create",
               "price" => "50",
               "initial_quantity" => "10",
               "max_per_order" => "1"
             })

    refute offer.sales_enabled
    assert {:ok, %{ledger_state: :healthy}} = ReservationLedger.get_availability(offer.id)
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "retry_inventory_initialization only works for safe first-time setup", %{
    event: event,
    actor: actor
  } do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "Retry Offer",
          ticket_type: "retry_offer",
          price_cents: 5000,
          currency: "ZAR",
          configured_quantity_available: 5,
          initial_quantity: 5,
          max_per_order: 1,
          sales_enabled: false,
          sales_channel: "whatsapp"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: true)

    assert {:ok, _} = OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)
    assert {:ok, %{ledger_state: :healthy}} = ReservationLedger.get_availability(offer.id)

    assert {:error, :inventory_retry_not_allowed} =
             OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "enable_offer refuses missing or inconsistent inventory", %{event: event, actor: actor} do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "No Inventory",
          ticket_type: "no_inventory",
          price_cents: 5000,
          currency: "ZAR",
          configured_quantity_available: 3,
          initial_quantity: 3,
          max_per_order: 1,
          sales_enabled: false,
          sales_channel: "whatsapp"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: true)

    assert {:error, :inventory_not_ready} =
             OfferManagement.enable_offer(actor, event.id, offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "update_offer edits allowed fields without changing configured quantity", %{
    event: event,
    actor: actor
  } do
    {:ok, offer} =
      OfferManagement.create_offer(actor, event.id, %{
        "name" => "Editable",
        "price" => "80",
        "regular_price" => "100",
        "initial_quantity" => "12",
        "max_per_order" => "3"
      })

    assert {:ok, updated} =
             OfferManagement.update_offer(actor, event.id, offer.id, %{
               "name" => "Editable VIP",
               "price" => "75",
               "regular_price" => "95",
               "max_per_order" => "2",
               "lock_version" => to_string(offer.lock_version)
             })

    assert updated.name == "Editable VIP"
    assert updated.price_cents == 7500
    assert updated.regular_price_cents == 9500
    assert updated.max_per_order == 2
    assert updated.configured_quantity_available == 12

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end
end
