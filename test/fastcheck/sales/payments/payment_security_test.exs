defmodule FastCheck.Sales.Payments.PaymentSecurityTest do
  use FastCheck.DataCase, async: false

  import ExUnit.CaptureLog

  alias FastCheck.Sales.Payments.PaymentVerification
  alias FastCheck.Sales.Payments.TestSupport
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

  test "outcome logs exclude authorization_url access_code email and raw payload", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents + 50,
        currency: attempt.currency
      )
    )

    log =
      capture_log(fn ->
        assert {:ok, :mismatch} = PaymentVerification.verify_attempt(attempt.id)
      end)

    refute log =~ "authorization_url"
    refute log =~ "access_code"
    refute log =~ "buyer-secret@example.com"
    refute log =~ "checkout.paystack.com/secret"
  end
end
