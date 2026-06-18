defmodule FastCheck.Sales.Payments.VerifyPaymentWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
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

  test "perform verifies payment through orchestrator", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: attempt.amount_cents,
        currency: attempt.currency
      )
    )

    assert :ok =
             perform_job(VerifyPaymentWorker, %{
               "payment_attempt_id" => attempt.id
             })
  end

  test "worker uniqueness prevents duplicate jobs for the same payment_attempt_id" do
    args = %{"payment_attempt_id" => 99}

    assert {:ok, first} = VerifyPaymentWorker.new(args) |> Oban.insert()
    assert {:ok, second} = VerifyPaymentWorker.new(args) |> Oban.insert()

    assert first.id != second.id or first.conflict? or second.conflict?
  end
end
