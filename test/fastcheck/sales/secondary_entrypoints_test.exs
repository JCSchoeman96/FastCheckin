defmodule FastCheck.Sales.SecondaryEntrypointsTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.SecondaryEntrypoints
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  @user %{id: "admin", username: "admin"}

  setup do
    event = WebFixtures.insert_event!()
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "admin")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer, event: event, event_id: event.id}
  end

  test "admin-assisted checkout uses approved checkout core", %{offer: offer} do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    params = %{
      "ticket_offer_id" => to_string(offer.id),
      "quantity" => "1",
      "buyer_name" => "Test Buyer"
    }

    assert {:ok, %{order_id: order_id, public_reference: ref}} =
             SecondaryEntrypoints.start_admin_checkout(@user, offer.event_id, params, idem)

    assert is_binary(ref)

    order =
      Order
      |> Query.filter(id == ^order_id)
      |> Ash.read_one!(authorize?: false)

    assert order.source_channel == "admin"
    assert order.status == "awaiting_payment"
  end

  test "admin checkout maps source_channel server-side and ignores spoofed params", %{
    offer: offer
  } do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    params = %{
      "ticket_offer_id" => to_string(offer.id),
      "quantity" => "1",
      "source_channel" => "whatsapp",
      "idempotency_key" => "client-spoof-key"
    }

    assert {:ok, %{order_id: order_id}} =
             SecondaryEntrypoints.start_admin_checkout(@user, offer.event_id, params, idem)

    order =
      Order
      |> Query.filter(id == ^order_id)
      |> Ash.read_one!(authorize?: false)

    assert order.source_channel == "admin"
    assert order.idempotency_key == idem
  end

  test "internal pilot checkout uses source_channel internal_pilot" do
    event = WebFixtures.insert_event!()
    offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "internal")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    idem = SecondaryEntrypoints.generate_idempotency_key()

    params = %{
      "ticket_offer_id" => to_string(offer.id),
      "quantity" => "1"
    }

    assert {:ok, %{order_id: order_id}} =
             SecondaryEntrypoints.start_internal_pilot_checkout(
               @user,
               offer.event_id,
               params,
               idem
             )

    order =
      Order
      |> Query.filter(id == ^order_id)
      |> Ash.read_one!(authorize?: false)

    assert order.source_channel == "internal_pilot"
  end

  test "duplicate submit reuses idempotency key until checkout succeeds", %{offer: offer} do
    idem = SecondaryEntrypoints.generate_idempotency_key()

    params = %{
      "ticket_offer_id" => to_string(offer.id),
      "quantity" => "1"
    }

    assert {:ok, %{order_id: first_id}} =
             SecondaryEntrypoints.start_admin_checkout(@user, offer.event_id, params, idem)

    assert {:ok, %{order_id: second_id}} =
             SecondaryEntrypoints.start_admin_checkout(@user, offer.event_id, params, idem)

    assert first_id == second_id

    new_idem = SecondaryEntrypoints.generate_idempotency_key()

    assert {:ok, %{order_id: third_id}} =
             SecondaryEntrypoints.start_admin_checkout(@user, offer.event_id, params, new_idem)

    assert third_id != first_id
  end

  test "admin-assisted lists offers with sales_channel admin or all only", %{event_id: event_id} do
    admin_offer =
      Fixtures.insert_offer!(event_id: event_id, sales_channel: "admin", name: "Admin")

    all_offer = Fixtures.insert_offer!(event_id: event_id, sales_channel: "all", name: "All")

    whatsapp_offer =
      Fixtures.insert_offer!(event_id: event_id, sales_channel: "whatsapp", name: "WA")

    internal_offer =
      Fixtures.insert_offer!(event_id: event_id, sales_channel: "internal", name: "Int")

    on_exit(fn ->
      Fixtures.flush_inventory_keys(admin_offer.id)
      Fixtures.flush_inventory_keys(all_offer.id)
      Fixtures.flush_inventory_keys(whatsapp_offer.id)
      Fixtures.flush_inventory_keys(internal_offer.id)
    end)

    actor = Fixtures.admin_actor([event_id])

    assert {:ok, offers} =
             SecondaryEntrypoints.list_offers_for_channel(actor, event_id, "admin")

    ids = Enum.map(offers, & &1.id) |> MapSet.new()
    assert MapSet.member?(ids, admin_offer.id)
    assert MapSet.member?(ids, all_offer.id)
    refute MapSet.member?(ids, whatsapp_offer.id)
    refute MapSet.member?(ids, internal_offer.id)
  end

  test "internal-pilot lists offers with sales_channel internal or all only", %{
    event_id: event_id
  } do
    internal_offer =
      Fixtures.insert_offer!(event_id: event_id, sales_channel: "internal", name: "Pilot")

    all_offer = Fixtures.insert_offer!(event_id: event_id, sales_channel: "all", name: "All2")

    admin_offer2 =
      Fixtures.insert_offer!(event_id: event_id, sales_channel: "admin", name: "Admin2")

    on_exit(fn ->
      Fixtures.flush_inventory_keys(internal_offer.id)
      Fixtures.flush_inventory_keys(all_offer.id)
      Fixtures.flush_inventory_keys(admin_offer2.id)
    end)

    actor = Fixtures.admin_actor([event_id])

    assert {:ok, offers} =
             SecondaryEntrypoints.list_offers_for_channel(actor, event_id, "internal")

    ids = Enum.map(offers, & &1.id) |> MapSet.new()
    assert MapSet.member?(ids, internal_offer.id)
    assert MapSet.member?(ids, all_offer.id)
    refute MapSet.member?(ids, admin_offer2.id)
  end

  test "disabled and archived offers are excluded from active lists", %{event_id: event_id} do
    disabled =
      Fixtures.insert_offer!(
        event_id: event_id,
        sales_channel: "admin",
        sales_enabled: false,
        name: "Disabled"
      )

    archived =
      Fixtures.insert_offer!(
        event_id: event_id,
        sales_channel: "admin",
        archived_at: DateTime.utc_now() |> DateTime.truncate(:second),
        name: "Archived"
      )

    on_exit(fn ->
      Fixtures.flush_inventory_keys(disabled.id)
      Fixtures.flush_inventory_keys(archived.id)
    end)

    actor = Fixtures.admin_actor([event_id])

    assert {:ok, offers} =
             SecondaryEntrypoints.list_offers_for_channel(actor, event_id, "admin")

    ids = MapSet.new(Enum.map(offers, & &1.id))
    refute MapSet.member?(ids, disabled.id)
    refute MapSet.member?(ids, archived.id)
  end

  test "safe_fetch_event returns not_found for missing event" do
    assert {:error, :not_found} = SecondaryEntrypoints.safe_fetch_event(99_999_999)
  end

  test "internal pilot returns pilot_disabled when config is false" do
    event = WebFixtures.insert_event!()
    pilot_offer = Fixtures.insert_offer!(event_id: event.id, sales_channel: "internal")
    on_exit(fn -> Fixtures.flush_inventory_keys(pilot_offer.id) end)

    previous = Application.get_env(:fastcheck, :sales_internal_pilot_enabled)

    Application.put_env(:fastcheck, :sales_internal_pilot_enabled, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:fastcheck, :sales_internal_pilot_enabled)
      else
        Application.put_env(:fastcheck, :sales_internal_pilot_enabled, previous)
      end
    end)

    assert {:error, :pilot_disabled} =
             SecondaryEntrypoints.start_internal_pilot_checkout(
               @user,
               pilot_offer.event_id,
               %{"ticket_offer_id" => to_string(pilot_offer.id), "quantity" => "1"},
               SecondaryEntrypoints.generate_idempotency_key()
             )
  end

  describe "strict integer parsing" do
    test "parse_event_id rejects partial and invalid strings" do
      for invalid <- ["1abc", " 1x", "abc", "0", "-1", ""] do
        assert {:error, :invalid} = SecondaryEntrypoints.parse_event_id(invalid)
      end

      assert {:ok, 1} = SecondaryEntrypoints.parse_event_id("1")
      assert {:ok, 42} = SecondaryEntrypoints.parse_event_id(" 42 ")
    end

    test "checkout form integers reject partial parses", %{offer: offer} do
      idem = SecondaryEntrypoints.generate_idempotency_key()

      for invalid_quantity <- ["1abc", " 1x", "abc", "0", "-1"] do
        assert {:error, :invalid_quantity} =
                 SecondaryEntrypoints.start_admin_checkout(
                   @user,
                   offer.event_id,
                   %{"ticket_offer_id" => to_string(offer.id), "quantity" => invalid_quantity},
                   idem
                 )
      end

      for invalid_offer_id <- ["1abc", " 1x", "abc", "0", "-1"] do
        assert {:error, :invalid_offer} =
                 SecondaryEntrypoints.start_admin_checkout(
                   @user,
                   offer.event_id,
                   %{"ticket_offer_id" => invalid_offer_id, "quantity" => "1"},
                   idem
                 )
      end
    end
  end
end
