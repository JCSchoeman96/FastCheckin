defmodule FastCheck.Sales.Payments.PaystackWebhookWorkerTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaymentRecovery
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.TestSupport
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.SalesCheckoutFixtures, as: Fixtures
  alias FastCheck.SalesE2EFixtures, as: E2E

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

  test "webhook attempt preparation requires the handoff transaction" do
    assert {:error, :transaction_required} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(FastCheck.Repo, fn ->
               PaymentRecovery.prepare_webhook_attempt(1)
             end)
  end

  test "late-webhook attempt transition rolls back when verify job insertion fails", %{
    offer: offer
  } do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
      [attempt.id, "payment_verification_recovery_exhausted"]
    )

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT fail_payment_verify_worker_insert_for_test CHECK (worker <> 'FastCheck.Sales.Payments.VerifyPaymentWorker') NOT VALID"
    )

    assert_raise Ecto.ConstraintError, fn ->
      perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})
    end

    assert payment_attempt_status(attempt.id) == "manual_review"
    assert payment_attempt_reason(attempt.id) == "payment_verification_recovery_exhausted"
    assert payment_event_status(event.id) == "stored"
    refute_enqueued(worker: VerifyPaymentWorker)

    Repo.query!(
      "ALTER TABLE oban_jobs DROP CONSTRAINT fail_payment_verify_worker_insert_for_test"
    )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})
    assert payment_attempt_status(attempt.id) == "verification_retry_queued"
    assert payment_event_status(event.id) == "processing_started"
    assert_enqueued(worker: VerifyPaymentWorker)
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

  test "perform does not hand off an unsigned payment event", %{offer: offer} do
    %{attempt: attempt} = TestSupport.initialized_payment!(offer)

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        signature_valid: false
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})
    refute_enqueued(worker: VerifyPaymentWorker)
  end

  test "a signed event for verified success only runs idempotent event finalization", %{
    offer: offer
  } do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert :ok =
             VerifyPaymentWorker.perform(%Oban.Job{
               args: %{"payment_attempt_id" => attempt.id},
               attempt: 1,
               max_attempts: 5
             })

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})

    assert [%{args: verify_args}] =
             all_enqueued(worker: VerifyPaymentWorker, args: %{"payment_event_id" => event.id})

    assert :ok = perform_job(VerifyPaymentWorker, verify_args)

    assert payment_attempt_status(attempt.id) == "verified_success"
    assert payment_event_status(event.id) == "processed"
    assert E2E.order_transition_count(order.id, "paid_verified") == 1

    assert transition_count("PaymentAttempt", attempt.id, "verified_success") == 1
    assert transition_count("PaymentAttempt", attempt.id, "verification_retry_queued") == 0
    assert :counters.get(request_count, 1) == 1
  end

  test "an active callback verification defers the event for bounded replay", %{offer: offer} do
    %{order: order, attempt: attempt} = TestSupport.initialized_payment!(offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
      [attempt.id, "payment_verification_recovery_exhausted"]
    )

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert {:ok, :enqueued} =
             PaymentRecovery.enqueue_verification_by_reference(attempt.provider_reference)

    event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        processing_status: "stored"
      })

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})
    assert payment_event_status(event.id) == "processing_started"

    assert [%{id: callback_job_id, args: callback_args}] =
             all_enqueued(worker: VerifyPaymentWorker)

    assert callback_args == %{"payment_attempt_id" => attempt.id}

    assert :ok = perform_job(VerifyPaymentWorker, callback_args)
    Repo.query!("UPDATE oban_jobs SET state = 'completed' WHERE id = $1", [callback_job_id])

    assert payment_attempt_status(attempt.id) == "verified_success"
    assert payment_event_status(event.id) == "processing_started"
    assert :counters.get(request_count, 1) == 1

    Repo.query!(
      "UPDATE sales_payment_events SET inserted_at = $2 WHERE id = $1",
      [event.id, DateTime.add(DateTime.utc_now(), -180, :second)]
    )

    assert {:ok, %{events_enqueued: 1}} = PaymentRecovery.sweep()
    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => event.id})

    assert [%{args: event_args}] =
             all_enqueued(
               worker: VerifyPaymentWorker,
               args: %{"payment_event_id" => event.id}
             )

    assert event_args["payment_attempt_id"] == attempt.id
    assert :ok = perform_job(VerifyPaymentWorker, event_args)

    assert payment_attempt_status(attempt.id) == "verified_success"
    assert payment_event_status(event.id) == "processed"
    assert E2E.order_transition_count(order.id, "paid_verified") == 1
    assert :counters.get(request_count, 1) == 1
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

  defp payment_attempt_status(id) do
    Repo.one!(
      from(attempt in "sales_payment_attempts", where: attempt.id == ^id, select: attempt.status)
    )
  end

  defp payment_attempt_reason(id) do
    Repo.one!(
      from(attempt in "sales_payment_attempts",
        where: attempt.id == ^id,
        select: attempt.manual_review_reason
      )
    )
  end

  defp payment_event_status(id) do
    Repo.one!(
      from(event in "sales_payment_events",
        where: event.id == ^id,
        select: event.processing_status
      )
    )
  end

  defp transition_count(entity_type, entity_id, to_state) do
    Repo.one!(
      from(transition in "sales_state_transitions",
        where:
          transition.entity_type == ^entity_type and
            transition.entity_id == ^to_string(entity_id) and transition.to_state == ^to_state,
        select: count(transition.id)
      )
    )
  end
end
