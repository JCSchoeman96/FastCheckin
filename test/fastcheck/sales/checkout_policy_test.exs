defmodule FastCheck.Sales.CheckoutPolicyTest do
  use FastCheck.DataCase, async: false

  alias Ash.Query
  alias FastCheck.Sales.Checkout
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.TicketOffer
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    offer = Fixtures.insert_offer!()
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)
    {:ok, offer: offer}
  end

  test "system actor can start checkout", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "policy-system-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "admin actor can start checkout for allowed event" do
    offer = Fixtures.insert_offer!(sales_channel: "admin")
    on_exit(fn -> Fixtures.flush_inventory_keys(offer.id) end)

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        source_channel: "admin",
        idempotency_key: "policy-admin-#{System.unique_integer([:positive])}"
      })

    assert {:ok, _} = Checkout.start_checkout(input, Fixtures.admin_actor(), [])
  end

  test "operator cannot start checkout" do
    offer = Fixtures.insert_offer!()

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "policy-operator-#{System.unique_integer([:positive])}"
      })

    assert {:error, :forbidden} =
             Checkout.start_checkout(input, Fixtures.operator_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "operator cannot replay checkout by idempotency key", %{offer: offer} do
    idem = "policy-operator-replay-#{System.unique_integer([:positive])}"

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:error, :forbidden} =
             Checkout.start_checkout(input, Fixtures.operator_actor(),
               effective_sales_channel: "whatsapp"
             )
  end

  test "customer_session cannot replay checkout by idempotency key without event access", %{
    offer: offer
  } do
    idem = "policy-customer-replay-#{System.unique_integer([:positive])}"

    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: idem
      })

    assert {:ok, _} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:error, :forbidden} =
             Checkout.start_checkout(
               input,
               Fixtures.customer_session_actor([offer.event_id + 99]),
               effective_sales_channel: "whatsapp"
             )
  end

  test "customer_session cannot broadly read orders", %{offer: offer} do
    input =
      Fixtures.checkout_input(%{
        ticket_offer_id: offer.id,
        idempotency_key: "policy-customer-#{System.unique_integer([:positive])}"
      })

    assert {:ok, %{order: order}} =
             Checkout.start_checkout(input, Fixtures.system_actor(),
               effective_sales_channel: "whatsapp"
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Order
             |> Query.for_read(:get_by_id, %{id: order.id},
               actor: Fixtures.customer_session_actor()
             )
             |> Ash.read_one(authorize?: true)
  end

  test "customer_session cannot use TicketOffer get_by_id directly" do
    offer = Fixtures.insert_offer!()

    assert {:error, %Ash.Error.Forbidden{}} =
             TicketOffer
             |> Query.for_read(:get_by_id, %{id: offer.id},
               actor: Fixtures.customer_session_actor()
             )
             |> Ash.read_one(authorize?: true)
  end
end
