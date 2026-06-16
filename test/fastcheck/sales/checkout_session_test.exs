defmodule FastCheck.Sales.CheckoutSessionTest do
  use FastCheck.DataCase, async: false

  alias Ash.Changeset
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "sales hold token pepper is configured from test config" do
    assert Application.fetch_env!(:fastcheck, :sales_hold_token_pepper) == "test-pepper"
  end

  test "attach_inventory_hold stores hold details and hashed token", %{offer: offer} do
    actor = Fixtures.system_actor()

    order =
      Order
      |> Changeset.for_create(
        :create_draft,
        %{
          public_reference: "FC-test-#{System.unique_integer([:positive])}",
          event_id: offer.event_id,
          source_channel: "test",
          total_amount_cents: 10_000,
          currency: "ZAR",
          idempotency_key: "session-order-#{System.unique_integer([:positive])}"
        },
        actor: actor
      )
      |> Ash.create!(authorize?: false)

    session =
      CheckoutSession
      |> Changeset.for_create(:create_session, %{sales_order_id: order.id}, actor: actor)
      |> Ash.create!(authorize?: false)

    hold_key = ReservationLedger.hold_key(order.public_reference)

    pepper = Application.fetch_env!(:fastcheck, :sales_hold_token_pepper)

    token_hash =
      :crypto.hash(:sha256, "opaque" <> pepper)
      |> Base.encode16(case: :lower)

    expires_at = DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)

    updated =
      session
      |> Changeset.for_update(
        :attach_inventory_hold,
        %{
          redis_hold_key: hold_key,
          hold_token: token_hash,
          hold_quantity: 1,
          expires_at: expires_at
        },
        actor: actor
      )
      |> Ash.update!(authorize?: false)

    assert updated.status == "hold_attached"
    assert updated.redis_hold_key == hold_key
    assert updated.hold_quantity == 1
    refute updated.hold_token == order.idempotency_key
  end

  test "hold_token is not raw idempotency key from checkout", %{offer: offer} do
    idem = "hold-hash-#{System.unique_integer([:positive])}"

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    assert {:ok, %{order: order, checkout_session: session}} =
             FastCheck.Sales.Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    persisted =
      CheckoutSession
      |> Ash.get!(session.id, authorize?: false)

    refute persisted.hold_token == idem
    refute persisted.hold_token == order.idempotency_key
    assert is_binary(persisted.hold_token)
    assert String.length(persisted.hold_token) == 64
  end
end
