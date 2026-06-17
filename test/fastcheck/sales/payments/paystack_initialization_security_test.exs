defmodule FastCheck.Sales.Payments.PaystackInitializationSecurityTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

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

  test "operator actor is forbidden", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    assert {:error, :forbidden} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.operator_actor()
             )
  end

  test "customer_session cannot initialize unrelated event checkout", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    assert {:error, :forbidden} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.customer_session_actor([99_999])
             )
  end

  test "customer_session can initialize scoped event checkout", %{offer: offer} do
    {_order, session} = TestSupport.checkout_ready_for_payment!(offer)

    Application.put_env(:fastcheck, :paystack_request_fun, TestSupport.success_request_fun())

    assert {:ok, _} =
             TransactionInitialization.initialize_for_checkout_session(
               session.id,
               Fixtures.customer_session_actor([offer.event_id])
             )
  end

  test "captured logs redact paystack secrets and sensitive payment fields", %{offer: offer} do
    {_order, session} =
      TestSupport.checkout_ready_for_payment!(offer, %{buyer_email: "pii-buyer@example.com"})

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.success_request_fun(
        authorization_url: "https://checkout.paystack.com/redact-me",
        access_code: "AC_REDACT"
      )
    )

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 TransactionInitialization.initialize_for_checkout_session(
                   session.id,
                   Fixtures.system_actor()
                 )
      end)

    refute log =~ "redact-me"
    refute log =~ "AC_REDACT"
    refute log =~ "pii-buyer@example.com"
    refute log =~ "Authorization"
    refute log =~ "sk_test_fake"
  end
end
