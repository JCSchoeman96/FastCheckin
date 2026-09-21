defmodule FastCheck.Sales.CheckoutOfferVersionTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias Ash
  alias Ash.Changeset
  alias FastCheck.Events
  alias FastCheck.Messaging.WhatsApp.WebhookTestSupport
  alias FastCheck.Repo
  alias FastCheck.Sales.Checkout
  alias FastCheck.SalesCheckoutFixtures, as: SalesFixtures
  alias FastCheckWeb.SalesWebFixtures

  setup do
    WebhookTestSupport.flush_redis_keys!()
    event = SalesWebFixtures.insert_event!(%{name: "Checkout Version Event"})
    {:ok, event} = Events.enable_whatsapp_sales(event.id)
    offer = SalesFixtures.insert_offer!(event_id: event.id, price_cents: 10_000)
    actor = SalesFixtures.customer_session_actor([event.id])

    on_exit(fn ->
      SalesFixtures.flush_inventory_keys(offer.id)
      WebhookTestSupport.flush_redis_keys!()
    end)

    {:ok, event: event, offer: offer, actor: actor}
  end

  test "checkout rejects stale expected offer lock version with zero side effects", %{
    event: event,
    offer: offer,
    actor: actor
  } do
    input =
      SalesFixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        expected_offer_lock_version: offer.lock_version - 1
      })

    assert {:error, :offer_changed} = Checkout.start_checkout(input, actor)

    assert Repo.aggregate(from(o in "sales_orders", select: count()), :count, :id) == 0
    assert Repo.aggregate(from(ol in "sales_order_lines", select: count()), :count, :id) == 0

    assert Repo.aggregate(from(cs in "sales_checkout_sessions", select: count()), :count, :id) ==
             0

    assert Repo.aggregate(from(pa in "sales_payment_attempts", select: count()), :count, :id) ==
             0
  end

  test "existing checkout idempotent replay is unaffected by later offer edits", %{
    event: event,
    offer: offer,
    actor: actor
  } do
    input =
      SalesFixtures.checkout_input(%{
        event_id: event.id,
        ticket_offer_id: offer.id,
        source_channel: "whatsapp",
        idempotency_key: "idem-offer-version-1"
      })

    assert {:ok, %{order: order}} = Checkout.start_checkout(input, actor)

    offer
    |> Changeset.for_update(
      :update_offer,
      %{price_cents: 15_000},
      actor: SalesFixtures.admin_actor([event.id])
    )
    |> Ash.update!(authorize?: false)

    assert {:ok, %{order: replayed}} = Checkout.start_checkout(input, actor)
    assert replayed.id == order.id

    line =
      Repo.one!(
        from(ol in "sales_order_lines",
          where: ol.sales_order_id == ^order.id,
          select: %{unit_amount_cents: ol.unit_amount_cents}
        )
      )

    assert line.unit_amount_cents == 10_000
  end
end
