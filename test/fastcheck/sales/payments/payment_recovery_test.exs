defmodule FastCheck.Sales.Payments.PaymentRecoveryTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.ManualReview

  alias FastCheck.Sales.Payments.{
    PaymentRecovery,
    PaymentRecoverySweepWorker,
    PaymentVerification,
    PaystackWebhookWorker,
    TestSupport,
    VerifyPaymentWorker,
    WebhookIngestion
  }

  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.PaidOrderFulfillmentWorker
  alias FastCheckWeb.SalesWebFixtures, as: WebFixtures

  setup do
    paystack_cleanup = TestSupport.setup_paystack!()
    TestSupport.flush_webhook_dedupe_keys!()
    {event, offer} = E2E.setup_sales_event_offer!()

    on_exit(fn ->
      SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      TestSupport.flush_webhook_dedupe_keys!()
      paystack_cleanup.()
    end)

    {:ok, event: event, offer: offer}
  end

  test "missing webhook is recovered through Paystack verification and paid-order handoff", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    age_attempt!(attempt.id, 180)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    assert payment_event_count() == 0
    assert :ok = perform_job(PaymentRecoverySweepWorker, %{})

    assert [%{args: %{"payment_attempt_id" => attempt_id} = args}] =
             all_enqueued(worker: VerifyPaymentWorker)

    assert attempt_id == attempt.id
    assert Map.keys(args) == ["payment_attempt_id"]
    assert :counters.get(request_count, 1) == 0

    assert :ok = perform_job(VerifyPaymentWorker, args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )

    assert payment_event_count() == 0
  end

  test "sweep selects all supported unresolved states within the age and horizon bounds", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: first} = E2E.start_initialized_checkout!(event, offer)

    recoverable =
      [
        "authorization_url_sent",
        "webhook_received",
        "verification_started",
        "verification_retry_queued"
      ]
      |> Enum.map(fn status ->
        attempt = TestSupport.insert_initialized_attempt!(order)
        set_attempt_status!(attempt.id, status)
        age_attempt!(attempt.id, 180)
        attempt
      end)

    age_attempt!(first.id, 180)

    fresh = TestSupport.insert_initialized_attempt!(order)
    age_attempt!(fresh.id, 30)

    outside_horizon = TestSupport.insert_initialized_attempt!(order)
    age_attempt!(outside_horizon.id, 960)

    assert {:ok, %{attempts_enqueued: 5}} = PaymentRecovery.sweep()

    enqueued_ids =
      all_enqueued(worker: VerifyPaymentWorker)
      |> Enum.map(& &1.args["payment_attempt_id"])
      |> Enum.sort()

    assert enqueued_ids == Enum.sort([first.id | Enum.map(recoverable, & &1.id)])
    refute fresh.id in enqueued_ids
    refute outside_horizon.id in enqueued_ids
  end

  test "sweep bounds each attempt batch", %{event: event, offer: offer} do
    set_application_env(:sales_payment_recovery_batch_size, 2)

    %{order: order, attempt: first} = E2E.start_initialized_checkout!(event, offer)
    second = TestSupport.insert_initialized_attempt!(order)
    third = TestSupport.insert_initialized_attempt!(order)

    Enum.each([first, second, third], &age_attempt!(&1.id, 180))

    assert {:ok, %{attempts_enqueued: 2}} = PaymentRecovery.sweep()
    assert length(all_enqueued(worker: VerifyPaymentWorker)) == 2
  end

  test "concurrent sweeps leave one verification job for an attempt", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    age_attempt!(attempt.id, 180)

    [first, second] = Enum.map(1..2, fn _ -> Task.async(&PaymentRecovery.sweep/0) end)

    assert {:ok, _} = Task.await(first, 10_000)
    assert {:ok, _} = Task.await(second, 10_000)
    assert [%{args: %{"payment_attempt_id" => id}}] = all_enqueued(worker: VerifyPaymentWorker)
    assert id == attempt.id
  end

  test "discarded verification jobs do not strand a stale verification_started attempt", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    age_attempt!(attempt.id, 180)

    attempt =
      attempt
      |> Changeset.for_update(:mark_verification_started, %{},
        actor: SalesCheckoutFixtures.system_actor([event.id])
      )
      |> Ash.update!(authorize?: false)

    old_job =
      VerifyPaymentWorker.new(%{"payment_attempt_id" => attempt.id})
      |> Oban.insert!()

    old_time = DateTime.add(DateTime.utc_now(), -360, :second)

    Repo.update_all(
      from(job in Oban.Job, where: job.id == ^old_job.id),
      set: [state: "discarded", inserted_at: old_time, scheduled_at: old_time]
    )

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
    )

    assert :ok = perform_job(PaymentRecoverySweepWorker, %{})
    assert [%{args: %{"payment_attempt_id" => id}}] = all_enqueued(worker: VerifyPaymentWorker)
    assert id == attempt.id

    assert :ok = perform_job(VerifyPaymentWorker, %{"payment_attempt_id" => attempt.id})

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
  end

  test "old initialized attempts from an application outage enter recovery-exhausted review", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    age_attempt!(attempt.id, 1_800)

    assert {:ok, _} = PaymentRecovery.sweep()

    reviewed = E2E.reload_payment_attempt!(attempt.id)
    assert reviewed.status == "manual_review"
    assert reviewed.manual_review_reason == "payment_verification_recovery_exhausted"
    assert E2E.reload_order!(order.id).status == "awaiting_payment"
    refute_enqueued(worker: VerifyPaymentWorker)
    refute_enqueued(worker: PaidOrderFulfillmentWorker)
  end

  test "expired checkout with an orphaned pending verification enters recovery-exhausted review",
       %{
         event: event,
         offer: offer
       } do
    %{order: order, session: session, attempt: attempt} =
      E2E.start_initialized_checkout!(event, offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: order.total_amount_cents,
        currency: order.currency,
        provider_status: "pending"
      )
    )

    assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_started"

    Repo.query!(
      "UPDATE sales_checkout_sessions SET expires_at = $2 WHERE id = $1",
      [session.id, DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:ok, :expired} = FastCheck.Sales.CheckoutExpiry.expire_session(session.id)
    age_attempt!(attempt.id, 1_800)

    assert {:ok, _} = PaymentRecovery.sweep()

    reviewed = E2E.reload_payment_attempt!(attempt.id)
    assert reviewed.status == "manual_review"
    assert reviewed.manual_review_reason == "payment_verification_recovery_exhausted"
    assert E2E.reload_order!(order.id).status == "expired"
    assert E2E.reload_session!(session.id).status == "expired"
    refute_enqueued(worker: VerifyPaymentWorker)
    refute_enqueued(worker: PaidOrderFulfillmentWorker)
  end

  test "a pending payment beyond the automatic horizon remains recoverable as manual review", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: order.total_amount_cents,
        currency: order.currency,
        provider_status: "pending"
      )
    )

    assert {:error, :retryable} = PaymentVerification.verify_attempt(attempt.id)
    age_attempt!(attempt.id, 1_800)

    assert {:ok, _} = PaymentRecovery.sweep()

    reviewed = E2E.reload_payment_attempt!(attempt.id)
    assert reviewed.status == "manual_review"
    assert reviewed.manual_review_reason == "payment_verification_recovery_exhausted"
    assert E2E.reload_order!(order.id).status == "awaiting_payment"
    refute_enqueued(worker: VerifyPaymentWorker)
    refute_enqueued(worker: PaidOrderFulfillmentWorker)
  end

  test "a pending provider result on the final verify attempt enters recovery-exhausted review",
       %{
         event: event,
         offer: offer
       } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: order.total_amount_cents,
        currency: order.currency,
        provider_status: "pending"
      )
    )

    job = %Oban.Job{
      args: %{"payment_attempt_id" => attempt.id},
      attempt: 5,
      max_attempts: 5
    }

    assert :ok = VerifyPaymentWorker.perform(job)

    reviewed = E2E.reload_payment_attempt!(attempt.id)
    assert reviewed.status == "manual_review"
    assert reviewed.manual_review_reason == "payment_verification_recovery_exhausted"
    assert E2E.reload_order!(order.id).status == "awaiting_payment"
    refute_enqueued(worker: PaidOrderFulfillmentWorker)
  end

  test "a live verify job prevents the horizon handoff", %{event: event, offer: offer} do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    attempt =
      attempt
      |> Changeset.for_update(:mark_verification_started, %{},
        actor: SalesCheckoutFixtures.system_actor([event.id])
      )
      |> Ash.update!(authorize?: false)

    age_attempt!(attempt.id, 1_800)
    job = VerifyPaymentWorker.new(%{"payment_attempt_id" => attempt.id}) |> Oban.insert!()
    old_time = DateTime.add(DateTime.utc_now(), -600, :second)

    Repo.update_all(
      from(row in Oban.Job, where: row.id == ^job.id),
      set: [inserted_at: old_time, scheduled_at: old_time]
    )

    assert {:ok, _} = PaymentRecovery.sweep()
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_started"
    assert Repo.get!(Oban.Job, job.id).state == "available"
    assert length(all_enqueued(worker: VerifyPaymentWorker)) == 1
  end

  test "an old operator retry remains recoverable if its queued job is discarded", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    set_attempt_manual_review!(attempt.id, "payment_state_conflict")
    age_attempt!(attempt.id, 7_200)
    actor = WebFixtures.dashboard_actor([event.id])

    assert {:ok, _action} =
             ManualReview.retry_payment_verification(
               attempt.id,
               actor,
               %{"reason_code" => "retry_payment_verification"}
             )

    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"
    assert [%{id: job_id}] = all_enqueued(worker: VerifyPaymentWorker)

    old_time = DateTime.add(DateTime.utc_now(), -600, :second)

    Repo.update_all(
      from(job in Oban.Job, where: job.id == ^job_id),
      set: [state: "discarded", inserted_at: old_time, scheduled_at: old_time]
    )

    assert {:ok, _} = PaymentRecovery.sweep()

    assert [%{args: %{"payment_attempt_id" => id}}] =
             all_enqueued(worker: VerifyPaymentWorker)

    assert id == attempt.id
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"
  end

  test "recovery-exhausted attempts can be restarted by a signed late webhook", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    set_attempt_manual_review!(attempt.id, "payment_verification_recovery_exhausted")

    %{event: payment_event, status: :created} =
      E2E.ingest_paystack_success!(attempt,
        provider_event_id: "late-after-recovery-#{System.unique_integer([:positive])}"
      )

    assert payment_event.signature_valid

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
    )

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"

    assert [%{args: args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert args["payment_attempt_id"] == attempt.id
    assert args["payment_event_id"] == payment_event.id
    assert :ok = perform_job(VerifyPaymentWorker, args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"
  end

  test "late webhook preserves retry intent while an exhausted verify job is still active", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    set_attempt_manual_review!(attempt.id, "payment_verification_recovery_exhausted")

    assert {:ok, active_job} =
             VerifyPaymentWorker.new(%{"payment_attempt_id" => attempt.id})
             |> Oban.insert()

    Repo.update_all(
      from(job in Oban.Job, where: job.id == ^active_job.id),
      set: [state: "executing"]
    )

    %{event: payment_event, status: :created} =
      E2E.ingest_paystack_success!(attempt,
        provider_event_id: "late-active-job-#{System.unique_integer([:positive])}"
      )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"

    Repo.update_all(
      from(job in Oban.Job, where: job.id == ^active_job.id),
      set: [state: "discarded"]
    )

    assert {:ok, _} = PaymentRecovery.sweep()

    assert [%{args: %{"payment_attempt_id" => id}}] =
             all_enqueued(worker: VerifyPaymentWorker)

    assert id == attempt.id
  end

  test "a signed duplicate webhook can restart the same exhausted event exactly once", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    webhook =
      E2E.ingest_paystack_success!(attempt,
        provider_event_id: "replay-after-exhaustion-#{System.unique_integer([:positive])}"
      )

    payment_event = webhook.event
    assert webhook.status == :created

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.init_and_verify_request_fun(
        amount: order.total_amount_cents,
        currency: order.currency,
        provider_status: "pending"
      )
    )

    verify_args = %{
      "payment_attempt_id" => attempt.id,
      "payment_event_id" => payment_event.id,
      "provider_reference" => attempt.provider_reference
    }

    assert :ok =
             VerifyPaymentWorker.perform(%Oban.Job{
               args: verify_args,
               attempt: 5,
               max_attempts: 5
             })

    assert E2E.reload_payment_attempt!(attempt.id).manual_review_reason ==
             "payment_verification_recovery_exhausted"

    assert E2E.reload_payment_event!(payment_event.id).processing_status == "manual_review"

    Repo.update_all(
      from(job in Oban.Job,
        where: job.worker == ^inspect(PaystackWebhookWorker),
        where: fragment("?->>'payment_event_id' = ?", job.args, ^to_string(payment_event.id))
      ),
      set: [state: "completed"]
    )

    Repo.update_all(
      from(job in Oban.Job,
        where: job.worker == ^inspect(VerifyPaymentWorker),
        where: fragment("?->>'payment_attempt_id' = ?", job.args, ^to_string(attempt.id))
      ),
      set: [state: "completed"]
    )

    assert {:ok, :duplicate, replayed_event} =
             WebhookIngestion.ingest(webhook.body, webhook.signature)

    assert replayed_event.id == payment_event.id
    assert payment_event_count() == 1
    assert [%{args: %{"payment_event_id" => id}}] = all_enqueued(worker: PaystackWebhookWorker)
    assert id == payment_event.id

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
    )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"

    assert [%{args: retried_verify_args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert retried_verify_args["payment_attempt_id"] == attempt.id
    assert :ok = perform_job(VerifyPaymentWorker, retried_verify_args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"
    assert length(all_enqueued(worker: PaidOrderFulfillmentWorker)) == 1
  end

  test "unrelated manual-review payments are not restarted by a signed webhook", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    set_attempt_manual_review!(attempt.id, "payment_state_conflict")

    payment_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        signature_valid: true,
        processing_status: "stored"
      })

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    assert E2E.reload_payment_attempt!(attempt.id).status == "manual_review"
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "manual_review"
    refute_enqueued(worker: VerifyPaymentWorker)
  end

  test "a signed webhook does not retry a terminal failed attempt", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    set_attempt_status!(attempt.id, "failed")

    payment_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        signature_valid: true,
        processing_status: "stored"
      })

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    assert E2E.reload_payment_attempt!(attempt.id).status == "failed"
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "manual_review"
    refute_enqueued(worker: VerifyPaymentWorker)
  end

  test "sweep re-drives each recoverable event state through the webhook worker", %{
    event: event,
    offer: offer
  } do
    payments = Enum.map(1..4, fn _ -> E2E.start_initialized_checkout!(event, offer) end)
    event_states = ["unmatched", "processing_started", "stored", "failed"]

    events =
      Enum.zip(payments, event_states)
      |> Enum.map(fn {%{attempt: attempt}, status} ->
        payment_event =
          TestSupport.insert_payment_event!(%{
            provider_reference: attempt.provider_reference,
            signature_valid: true,
            processing_status: status
          })

        age_event!(payment_event.id, 180)
        payment_event
      end)

    assert {:ok, %{events_enqueued: 4}} = PaymentRecovery.sweep()

    Enum.each(events, fn payment_event ->
      assert_enqueued(
        worker: PaystackWebhookWorker,
        args: %{"payment_event_id" => payment_event.id}
      )
    end)

    refute_enqueued(worker: VerifyPaymentWorker)

    Enum.each(events, fn payment_event ->
      assert :ok =
               perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})
    end)

    Enum.zip(payments, events)
    |> Enum.each(fn {%{attempt: attempt}, payment_event} ->
      assert_enqueued(
        worker: VerifyPaymentWorker,
        args: %{
          "payment_attempt_id" => attempt.id,
          "payment_event_id" => payment_event.id,
          "provider_reference" => attempt.provider_reference
        }
      )
    end)

    attempt_amounts =
      Map.new(payments, fn payment -> {payment.attempt.id, payment.order.total_amount_cents} end)

    Enum.each(all_enqueued(worker: VerifyPaymentWorker), fn %{args: args} ->
      Application.put_env(
        :fastcheck,
        :paystack_request_fun,
        TestSupport.verify_success_request_fun(
          amount: Map.fetch!(attempt_amounts, args["payment_attempt_id"])
        )
      )

      assert :ok = perform_job(VerifyPaymentWorker, args)
    end)

    Enum.each(events, fn payment_event ->
      assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"
    end)

    Enum.each(payments, fn %{attempt: attempt, order: order} ->
      assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
      assert E2E.reload_order!(order.id).status == "paid_verified"
    end)
  end

  test "an unmatched event is retried after its matching attempt becomes available", %{
    event: event,
    offer: offer
  } do
    provider_reference = "late-match-#{System.unique_integer([:positive])}"

    payment_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: provider_reference,
        signature_valid: true,
        processing_status: "unmatched"
      })

    age_event!(payment_event.id, 180)

    %{order: order, attempt: initialized_attempt} =
      E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET provider_reference = $1 WHERE id = $2",
      [provider_reference, initialized_attempt.id]
    )

    attempt = E2E.reload_payment_attempt!(initialized_attempt.id)

    assert payment_event_count() == 1
    assert {:ok, %{events_enqueued: 1}} = PaymentRecovery.sweep()

    assert_enqueued(
      worker: PaystackWebhookWorker,
      args: %{"payment_event_id" => payment_event.id}
    )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    verify_args = %{
      "payment_attempt_id" => attempt.id,
      "payment_event_id" => payment_event.id,
      "provider_reference" => provider_reference
    }

    assert_enqueued(worker: VerifyPaymentWorker, args: verify_args)

    Application.put_env(
      :fastcheck,
      :paystack_request_fun,
      TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
    )

    assert :ok = perform_job(VerifyPaymentWorker, verify_args)
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert payment_event_count() == 1
  end

  test "a recoverable event is re-driven after its attempt already reached verified_success", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)
    assert :ok = perform_job(VerifyPaymentWorker, %{"payment_attempt_id" => attempt.id})
    assert :counters.get(request_count, 1) == 1

    payment_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: attempt.provider_reference,
        signature_valid: true,
        processing_status: "processing_started"
      })

    assert payment_event.signature_valid
    assert payment_event.provider_reference == attempt.provider_reference
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert [] == all_enqueued(worker: VerifyPaymentWorker)

    age_event!(payment_event.id, 180)

    assert {:ok, %{events_enqueued: 1}} = PaymentRecovery.sweep()

    assert_enqueued(
      worker: PaystackWebhookWorker,
      args: %{"payment_event_id" => payment_event.id}
    )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processing_started"

    verify_args = %{
      "payment_attempt_id" => attempt.id,
      "payment_event_id" => payment_event.id,
      "provider_reference" => attempt.provider_reference
    }

    assert_enqueued(worker: VerifyPaymentWorker, args: verify_args)
    assert :ok = perform_job(VerifyPaymentWorker, verify_args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert length(all_enqueued(worker: PaidOrderFulfillmentWorker)) == 1
  end

  test "a signed event without a reference does not stop the attempt recovery batch", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    age_attempt!(attempt.id, 180)

    payment_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: nil,
        signature_valid: true,
        processing_status: "stored"
      })

    age_event!(payment_event.id, 180)

    assert {:ok, %{attempts_enqueued: 1, events_enqueued: 1}} = PaymentRecovery.sweep()
    assert_enqueued(worker: VerifyPaymentWorker, args: %{"payment_attempt_id" => attempt.id})

    assert_enqueued(
      worker: PaystackWebhookWorker,
      args: %{"payment_event_id" => payment_event.id}
    )

    assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})
    assert E2E.reload_payment_event!(payment_event.id).processing_status == "unmatched"
  end

  test "terminal attempts and unsigned events are excluded from automatic recovery", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: initial} = E2E.start_initialized_checkout!(event, offer)

    terminal_attempts =
      [
        "verified_success",
        "verified_amount_mismatch",
        "verified_currency_mismatch",
        "duplicate",
        "manual_review",
        "failed",
        "refunded"
      ]
      |> Enum.map(fn status ->
        attempt = TestSupport.insert_initialized_attempt!(order)
        set_attempt_status!(attempt.id, status)
        age_attempt!(attempt.id, 180)
        attempt
      end)

    age_attempt!(initial.id, 180)
    set_attempt_status!(initial.id, "failed")

    failed_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: Enum.at(terminal_attempts, 5).provider_reference,
        signature_valid: true,
        processing_status: "failed"
      })

    unsigned_event =
      TestSupport.insert_payment_event!(%{
        provider_reference: initial.provider_reference,
        signature_valid: false,
        processing_status: "stored"
      })

    age_event!(failed_event.id, 180)
    age_event!(unsigned_event.id, 180)

    assert {:ok, %{attempts_enqueued: 0, events_enqueued: 0}} = PaymentRecovery.sweep()
    refute_enqueued(worker: VerifyPaymentWorker)
    refute_enqueued(worker: PaystackWebhookWorker)
  end

  defp age_attempt!(id, seconds) do
    Repo.query!(
      "UPDATE sales_payment_attempts SET inserted_at = $1 WHERE id = $2",
      [DateTime.add(DateTime.utc_now(), -seconds, :second), id]
    )
  end

  defp set_attempt_status!(id, status) do
    Repo.query!("UPDATE sales_payment_attempts SET status = $1 WHERE id = $2", [status, id])
  end

  defp set_attempt_manual_review!(id, reason) do
    attempt = E2E.reload_payment_attempt!(id)

    attempt
    |> Changeset.for_update(
      :mark_manual_review,
      %{manual_review_reason: reason},
      reason: reason,
      actor: SalesCheckoutFixtures.system_actor()
    )
    |> Ash.update!(authorize?: false)
  end

  defp age_event!(id, seconds) do
    Repo.query!(
      "UPDATE sales_payment_events SET inserted_at = $1 WHERE id = $2",
      [DateTime.add(DateTime.utc_now(), -seconds, :second), id]
    )
  end

  defp payment_event_count do
    Repo.one!(from(event in "sales_payment_events", select: count(event.id)))
  end

  defp set_application_env(key, value) do
    previous = Application.get_env(:fastcheck, key)
    Application.put_env(:fastcheck, key, value)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fastcheck, key),
        else: Application.put_env(:fastcheck, key, previous)
    end)
  end
end
