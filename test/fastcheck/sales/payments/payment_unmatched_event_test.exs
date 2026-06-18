defmodule FastCheck.Sales.Payments.PaymentUnmatchedEventTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
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

  test "unmatched event is retained and not deleted" do
    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: "missing-ref-#{System.unique_integer([:positive])}",
        processing_status: "stored"
      })

    assert :ok =
             PaystackWebhookWorker.perform(%Oban.Job{args: %{"payment_event_id" => event.id}})

    persisted =
      PaymentEvent
      |> Ash.Query.for_read(:get_by_id, %{id: event.id})
      |> Ash.read_one!(authorize?: false)

    assert persisted.processing_status == "unmatched"
    assert persisted.last_processing_error =~ "no_matching_payment_attempt"
  end

  test "unmatched event retries when payment attempt appears later", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    matched_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    assert :ok =
             PaystackWebhookWorker.perform(%Oban.Job{
               args: %{"payment_event_id" => matched_event.id}
             })

    updated =
      PaymentEvent
      |> Ash.Query.for_read(:get_by_id, %{id: matched_event.id})
      |> Ash.read_one!(authorize?: false)

    assert updated.processing_status == "processing_started"
  end
end
