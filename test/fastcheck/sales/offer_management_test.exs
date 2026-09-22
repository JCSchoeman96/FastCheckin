defmodule FastCheck.Sales.OfferManagementTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash.Changeset
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

  test "create_offer accepts max_per_order 12 when inventory is 20", %{event: event, actor: actor} do
    assert {:ok, offer} =
             OfferManagement.create_offer(actor, event.id, %{
               "name" => "Double Digit Max",
               "price" => "100",
               "initial_quantity" => "20",
               "max_per_order" => "12"
             })

    assert offer.max_per_order == 12
    assert offer.configured_quantity_available == 20
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "update_offer can raise max_per_order to 12 and increments lock_version", %{
    event: event,
    actor: actor
  } do
    {:ok, offer} =
      OfferManagement.create_offer(actor, event.id, %{
        "name" => "Raise Max",
        "price" => "80",
        "initial_quantity" => "20",
        "max_per_order" => "2"
      })

    assert {:ok, updated} =
             OfferManagement.update_offer(actor, event.id, offer.id, %{
               "name" => "Raise Max",
               "price" => "80",
               "max_per_order" => "12",
               "lock_version" => to_string(offer.lock_version)
             })

    assert updated.max_per_order == 12
    assert updated.lock_version == offer.lock_version + 1
    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "max_per_order above configured inventory is rejected", %{event: event, actor: actor} do
    assert {:error, :max_per_order_exceeds_inventory} =
             OfferManagement.create_offer(actor, event.id, %{
               "name" => "Too High Max",
               "price" => "50",
               "initial_quantity" => "10",
               "max_per_order" => "12"
             })
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

  test "create_offer persists disabled offer when redis initialization fails", %{
    event: event,
    actor: actor
  } do
    SalesFixtures.with_redis_stopped(fn ->
      assert {:error, :inventory_initialization_failed} =
               OfferManagement.create_offer(actor, event.id, %{
                 "name" => "Redis Down Create",
                 "price" => "60",
                 "initial_quantity" => "8",
                 "max_per_order" => "1",
                 "sales_enabled" => "true"
               })

      offer =
        Repo.one!(
          from(o in "sales_ticket_offers",
            where: o.name == "Redis Down Create" and o.event_id == ^event.id,
            select: map(o, [:id, :sales_enabled])
          )
        )

      refute offer.sales_enabled
      assert {:error, _, _} = ReservationLedger.get_availability(offer.id)
    end)
  end

  test "safe retry refuses offers referenced by order lines", %{event: event, actor: actor} do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "Order Line Offer",
          ticket_type: "order_line_offer",
          price_cents: 5000,
          currency: "ZAR",
          configured_quantity_available: 4,
          initial_quantity: 4,
          max_per_order: 1,
          sales_enabled: false,
          sales_channel: "whatsapp"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: true)

    order_id =
      Repo.query!(
        """
        INSERT INTO sales_orders
          (public_reference, event_id, buyer_name, buyer_phone, buyer_email, source_channel,
           status, total_amount_cents, currency, inserted_at, updated_at)
        VALUES
          ($1, $2, 'Buyer', '+27820000000', 'buyer@example.com', 'whatsapp',
           'draft', 5000, 'ZAR', now(), now())
        RETURNING id
        """,
        ["FC-#{System.unique_integer([:positive])}", event.id]
      )
      |> Map.fetch!(:rows)
      |> List.first()
      |> List.first()

    Repo.query!(
      """
      INSERT INTO sales_order_lines
        (sales_order_id, ticket_offer_id, line_number, ticket_type, offer_name_snapshot,
         event_name_snapshot, quantity, unit_amount_cents, total_amount_cents, currency,
         inserted_at, updated_at)
      VALUES
        ($1, $2, 1, 'general', 'Order Line Offer', 'Event', 1, 5000, 5000, 'ZAR', now(), now())
      """,
      [order_id, offer.id]
    )

    assert {:error, :inventory_retry_not_allowed} =
             OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "safe retry refuses an already-existing redis ledger even with active reservations", %{
    event: event,
    actor: actor
  } do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "Reserved Ledger",
          ticket_type: "reserved_ledger",
          price_cents: 5000,
          currency: "ZAR",
          configured_quantity_available: 6,
          initial_quantity: 6,
          max_per_order: 1,
          sales_enabled: false,
          sales_channel: "whatsapp"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: true)

    assert :ok = ReservationLedger.initialize_offer_if_absent(offer.id, 6)

    assert {:ok, _} =
             ReservationLedger.reserve(
               offer.id,
               "ORD-RETRY-#{System.unique_integer([:positive])}",
               1,
               120,
               "idem-retry-#{System.unique_integer([:positive])}"
             )

    assert {:error, :inventory_retry_not_allowed} =
             OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)

    assert {:ok, snapshot} = ReservationLedger.get_availability(offer.id)
    assert snapshot.reserved_quantity == 1

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "safe retry refuses an already-existing redis ledger", %{event: event, actor: actor} do
    {:ok, offer} =
      OfferManagement.create_offer(actor, event.id, %{
        "name" => "Existing Ledger",
        "price" => "40",
        "initial_quantity" => "6",
        "max_per_order" => "1"
      })

    assert {:error, :inventory_retry_not_allowed} =
             OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "safe retry refuses redis unavailable state", %{event: event, actor: actor} do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "Retry Redis Down",
          ticket_type: "retry_redis_down",
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

    SalesFixtures.with_redis_stopped(fn ->
      assert {:error, :inventory_retry_not_allowed} =
               OfferManagement.retry_inventory_initialization(actor, event.id, offer.id)
    end)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end

  test "enable_offer refuses durable and redis configured quantity mismatch", %{
    event: event,
    actor: actor
  } do
    offer =
      TicketOffer
      |> Changeset.for_create(
        :create_offer,
        %{
          event_id: event.id,
          name: "Mismatch Inventory",
          ticket_type: "mismatch_inventory",
          price_cents: 5000,
          currency: "ZAR",
          configured_quantity_available: 10,
          initial_quantity: 10,
          max_per_order: 1,
          sales_enabled: false,
          sales_channel: "whatsapp"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: true)

    assert :ok = ReservationLedger.initialize_offer(offer.id, 7)

    assert {:error, :inventory_not_ready} =
             OfferManagement.enable_offer(actor, event.id, offer.id)

    on_exit(fn -> SalesFixtures.flush_inventory_keys(offer.id) end)
  end
end
