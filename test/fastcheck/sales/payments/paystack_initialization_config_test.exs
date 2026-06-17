defmodule FastCheck.Sales.Payments.PaystackInitializationConfigTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.TransactionInitialization
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

  test "missing paystack secret returns safe config error without calling provider", %{
    offer: offer
  } do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.delete_env(:fastcheck, :paystack_secret_key)

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, %{type: :missing_config}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
    refute inspect({:error, %{type: :missing_config}}) =~ "sk_"
  end

  test "disabled paystack returns safe config error without calling provider", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(:fastcheck, :paystack_enabled, false)

    {request_fun, counter} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:error, %{type: :missing_config}} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.system_actor()
             )

    assert :counters.get(counter, 1) == 0
  end
end
