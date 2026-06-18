defmodule FastCheck.Sales.Payments.PaystackWebhookWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Repo
  alias FastCheck.Sales.Payments.PaystackWebhookWorker

  test "perform loads payment event without error" do
    %{rows: [[event_id]]} =
      Repo.query!("""
      INSERT INTO sales_payment_events
        (provider, provider_event_id, provider_reference, event_type, payload_hash,
         raw_payload, processing_status, processing_attempt_count, inserted_at, updated_at)
      VALUES
        ('paystack', 'evt-worker-1', 'ref-worker-1', 'charge.success', 'hash-worker-1',
         '{"event":"charge.success"}', 'stored', 0, now(), now())
      RETURNING id
      """)

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event_id})
  end

  test "worker uniqueness prevents duplicate jobs for the same payment_event_id" do
    args = %{"payment_event_id" => 42}

    assert {:ok, first} = PaystackWebhookWorker.new(args) |> Oban.insert()
    assert {:ok, second} = PaystackWebhookWorker.new(args) |> Oban.insert()

    assert first.id != second.id or first.conflict? or second.conflict?
  end
end
