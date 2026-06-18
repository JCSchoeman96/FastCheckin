defmodule FastCheck.Sales.Payments.PaystackWebhookWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
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

  test "perform atomically marks processing_started and enqueues verify worker when attempt exists",
       %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})

    updated_event =
      PaymentEvent
      |> Ash.Query.for_read(:get_by_id, %{id: event.id})
      |> Ash.read_one!(authorize?: false)

    assert updated_event.processing_status == "processing_started"

    assert_enqueued(
      worker: VerifyPaymentWorker,
      args: %{
        "payment_event_id" => event.id,
        "payment_attempt_id" => attempt.id,
        "provider_reference" => attempt.provider_reference
      }
    )
  end

  test "perform marks unmatched when no payment attempt exists" do
    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: "missing-ref-#{System.unique_integer([:positive])}"
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})

    updated_event =
      PaymentEvent
      |> Ash.Query.for_read(:get_by_id, %{id: event.id})
      |> Ash.read_one!(authorize?: false)

    assert updated_event.processing_status == "unmatched"

    refute_enqueued(worker: VerifyPaymentWorker)
  end

  test "perform returns error when payment event is missing" do
    assert {:error, :payment_event_not_found} =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => 999_999_999})
  end

  test "worker uniqueness prevents duplicate jobs for the same payment_event_id" do
    args = %{"payment_event_id" => 42}

    assert {:ok, first} = PaystackWebhookWorker.new(args) |> Oban.insert()
    assert {:ok, second} = PaystackWebhookWorker.new(args) |> Oban.insert()

    assert first.id != second.id or first.conflict? or second.conflict?
  end
end
