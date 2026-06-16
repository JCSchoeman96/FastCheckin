defmodule FastCheck.Sales.OrderLineSnapshotTest do
  use FastCheck.DataCase, async: false

  alias Ash.Query
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.TicketOffer
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  test "order line snapshots price and offer name" do
    offer = Fixtures.insert_offer!(price_cents: 15_000, name: "VIP Pass")

    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        quantity: 2,
        event_name: "Summer Fest",
        idempotency_key: "snapshot-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert [line] =
             OrderLine
             |> Query.for_read(:list_for_order, %{sales_order_id: order.id})
             |> Ash.read!(authorize?: false)

    assert line.offer_name_snapshot == "VIP Pass"
    assert line.event_name_snapshot == "Summer Fest"
    assert line.unit_amount_cents == 15_000
    assert line.total_amount_cents == 30_000
    assert line.quantity == 2
    assert order.total_amount_cents == 30_000

    updated_offer =
      TicketOffer
      |> Ash.get!(offer.id, authorize?: false)
      |> Ash.Changeset.for_update(:update_offer, %{price_cents: 99_999},
        actor: Fixtures.admin_actor()
      )
      |> Ash.update!(authorize?: false)

    assert updated_offer.price_cents == 99_999
    assert line.unit_amount_cents == 15_000
  end
end
