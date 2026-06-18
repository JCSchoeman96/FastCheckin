defmodule FastCheck.Sales.Payments.WebhookIngestionTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias Ecto.Multi
  alias FastCheck.Repo
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport, as: PaystackSupport
  alias FastCheck.Sales.Payments.WebhookIngestion

  setup do
    PaystackSupport.setup_paystack!()
    PaystackSupport.flush_webhook_dedupe_keys!()
    on_exit(fn -> PaystackSupport.flush_webhook_dedupe_keys!() end)
    :ok
  end

  test "ingest stores payment event and enqueues worker atomically" do
    body = PaystackSupport.charge_success_webhook_body()
    signature = PaystackSupport.sign_webhook_body(body)

    assert {:ok, :created, event} =
             WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})

    assert event.processing_status == "stored"
    assert event.signature_valid == true
    assert count_payment_events() == 1
    assert_enqueued(worker: PaystackWebhookWorker, args: %{"payment_event_id" => event.id})
  end

  test "payload_hash fallback dedupes when provider_event_id is absent" do
    body = PaystackSupport.charge_success_webhook_body(no_event_id: true)
    signature = PaystackSupport.sign_webhook_body(body)

    assert {:ok, :created, _} =
             WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})

    assert {:ok, :duplicate, _} =
             WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})

    assert count_payment_events() == 1
  end

  test "duplicate retry enqueues missing worker job before returning duplicate" do
    event_id = "evt-recover-#{System.unique_integer([:positive])}"
    body = PaystackSupport.charge_success_webhook_body(provider_event_id: event_id)
    signature = PaystackSupport.sign_webhook_body(body)

    assert {:ok, :created, event} =
             WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})

    Repo.delete_all(from(j in Oban.Job, where: j.worker == ^to_string(PaystackWebhookWorker)))

    assert {:ok, :duplicate, returned} =
             WebhookIngestion.ingest(body, %{"x-paystack-signature" => signature})

    assert returned.id == event.id

    assert_enqueued(worker: PaystackWebhookWorker, args: %{"payment_event_id" => event.id})
  end

  test "Ecto.Multi rolls back payment event when a later step fails" do
    attrs = %{
      provider: "paystack",
      provider_event_id: "evt-multi-rollback",
      provider_reference: "ref-multi",
      event_type: "charge.success",
      signature_valid: true,
      payload_hash: "hash-multi-rollback",
      raw_payload: %{"event" => "charge.success"},
      received_at: DateTime.utc_now() |> DateTime.truncate(:second),
      processing_status: "stored",
      processing_attempt_count: 0
    }

    changeset = PaymentEvent |> Changeset.for_create(:store_webhook_event, attrs)

    result =
      Multi.new()
      |> Multi.run(:payment_event, fn _repo, _ ->
        case Ash.create(changeset,
               authorize?: false,
               domain: FastCheck.Sales,
               return_notifications?: true
             ) do
          {:ok, event, _notifications} -> {:ok, event}
          {:ok, event} -> {:ok, event}
          {:error, error} -> {:error, error}
        end
      end)
      |> Multi.run(:fail, fn _repo, _ -> {:error, :forced_failure} end)
      |> Repo.transaction()

    assert {:error, :fail, :forced_failure, _} = result
    assert count_payment_events() == 0
  end

  defp count_payment_events do
    %{rows: [[count]]} = Repo.query!("SELECT count(*)::int FROM sales_payment_events")
    count
  end
end
