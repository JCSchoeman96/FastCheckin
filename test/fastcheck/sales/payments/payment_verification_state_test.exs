defmodule FastCheck.Sales.Payments.PaymentVerificationStateTest do
  use FastCheck.DataCase, async: false

  require Ash.Query

  alias Ash.Query
  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.StateTransition
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    offer = Fixtures.insert_offer!()

    on_exit(fn ->
      Fixtures.flush_inventory_keys(offer.id)
      paystack_cleanup.()
    end)

    {:ok, offer: offer}
  end

  test "successful verification appends state transitions for attempt order and session", %{
    offer: offer
  } do
    %{order: order, session: session, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert {:ok, :verified} = PaymentVerification.verify_attempt(attempt.id)

    assert Enum.any?(
             transitions_for("PaymentAttempt", attempt.id),
             &(&1.to_state == "verified_success")
           )

    assert Enum.any?(
             transitions_for("Order", order.id),
             &(&1.to_state == "paid_verified")
           )

    assert Enum.any?(
             transitions_for("CheckoutSession", session.id),
             &(&1.to_state == "paid")
           )
  end

  defp transitions_for(entity_type, entity_id) do
    StateTransition
    |> Query.for_read(:list_for_entity, %{
      entity_type: entity_type,
      entity_id: to_string(entity_id)
    })
    |> Ash.read!(authorize?: false)
  end
end
