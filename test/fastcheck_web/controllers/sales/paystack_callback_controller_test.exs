defmodule FastCheckWeb.Sales.PaystackCallbackControllerTest do
  use FastCheckWeb.ConnCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  import Ecto.Query

  alias FastCheck.Sales.Payments.{
    PaymentRecovery,
    PaystackWebhookWorker,
    TestSupport,
    VerifyPaymentWorker,
    WebhookIngestion
  }

  alias FastCheck.Repo
  alias FastCheck.SalesCheckoutFixtures
  alias FastCheck.SalesE2EFixtures, as: E2E
  alias FastCheck.Workers.{IssueTicketsWorker, PaidOrderFulfillmentWorker}

  @callback_path "/sales/payments/paystack/callback"

  setup do
    original_request_fun = Application.get_env(:fastcheck, :paystack_request_fun)
    paystack_cleanup = TestSupport.setup_paystack!()
    TestSupport.flush_webhook_dedupe_keys!()
    {event, offer} = E2E.setup_sales_event_offer!()

    on_exit(fn ->
      SalesCheckoutFixtures.flush_inventory_keys(offer.id)
      TestSupport.flush_webhook_dedupe_keys!()
      paystack_cleanup.()

      if is_nil(original_request_fun),
        do: Application.delete_env(:fastcheck, :paystack_request_fun),
        else: Application.put_env(:fastcheck, :paystack_request_fun, original_request_fun)
    end)

    {:ok, event: event, offer: offer}
  end

  test "callback route suppresses dispatch logging of query parameters" do
    route =
      Enum.find(FastCheckWeb.Router.__routes__(), &(&1.path == @callback_path))

    assert %{
             verb: :get,
             metadata: %{log: false},
             plug: FastCheckWeb.Sales.PaystackCallbackController
           } =
             route
  end

  test "callback reference queues verification and status=success is not payment authority", %{
    conn: conn,
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn =
      get(conn, @callback_path, %{
        "reference" => attempt.provider_reference,
        "status" => "success",
        "amount" => "1",
        "currency" => "USD",
        "email" => "attacker@example.test"
      })

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    assert conn.resp_body =~ "You can return to WhatsApp."

    assert conn.resp_body =~
             "If Paystack confirms the payment, your ticket will be processed automatically."

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert [_csp] = get_resp_header(conn, "content-security-policy")

    page_and_headers =
      conn.resp_body <>
        Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)

    refute page_and_headers =~ attempt.provider_reference
    refute page_and_headers =~ order.public_reference
    refute page_and_headers =~ order.buyer_email
    refute page_and_headers =~ order.buyer_phone
    refute page_and_headers =~ Integer.to_string(order.total_amount_cents)
    refute page_and_headers =~ "attacker@example.test"

    assert E2E.reload_payment_attempt!(attempt.id).status == "initialized"
    refute E2E.reload_order!(order.id).status == "paid_verified"
    assert :counters.get(request_count, 1) == 0
    assert_enqueued(worker: VerifyPaymentWorker, args: %{"payment_attempt_id" => attempt.id})
  end

  test "successful callback handoff uses the normal server-side verification lifecycle", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn =
      get(build_conn(), @callback_path, %{
        "reference" => attempt.provider_reference,
        "trxref" => attempt.provider_reference
      })

    assert conn.status == 200
    assert :counters.get(request_count, 1) == 0

    assert [%{args: args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert args == %{"payment_attempt_id" => attempt.id}
    assert :ok = perform_job(VerifyPaymentWorker, args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"

    assert_enqueued(
      worker: PaidOrderFulfillmentWorker,
      args: %{"payment_attempt_id" => attempt.id}
    )
  end

  test "invalid and unknown references share a safe response and create no payment work", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)
    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    inputs = [
      %{"status" => "success"},
      %{"reference" => ""},
      %{"reference" => String.duplicate("a", 101)},
      %{"reference" => "unsupported*value"},
      %{"reference" => attempt.provider_reference, "trxref" => "different-reference"},
      %{"reference" => "valid-but-unknown-reference"}
    ]

    responses =
      Enum.map(inputs, fn params ->
        conn = get(build_conn(), @callback_path, params)
        assert conn.status == 200
        assert get_resp_header(conn, "cache-control") == ["no-store"]
        assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
        assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
        conn
      end)

    assert Enum.map(responses, & &1.resp_body) |> Enum.uniq() |> length() == 1

    page_and_headers =
      Enum.map_join(responses, "\n", fn conn ->
        conn.resp_body <>
          Enum.map_join(conn.resp_headers, "\n", fn {name, value} -> "#{name}: #{value}" end)
      end)

    refute page_and_headers =~ attempt.provider_reference
    refute page_and_headers =~ order.public_reference
    refute page_and_headers =~ order.buyer_email
    refute page_and_headers =~ order.buyer_phone
    assert E2E.reload_payment_attempt!(attempt.id).status == "initialized"
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 0
  end

  test "known terminal references receive the safe page without re-verification", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!("UPDATE sales_payment_attempts SET status = 'manual_review' WHERE id = $1", [
      attempt.id
    ])

    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    refute conn.resp_body =~ attempt.provider_reference
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 0
    assert E2E.reload_payment_attempt!(attempt.id).status == "manual_review"
  end

  test "an old unresolved callback waits for the sweep to hand it to manual review", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET inserted_at = $2 WHERE id = $1",
      [attempt.id, DateTime.add(DateTime.utc_now(), -1_800, :second)]
    )

    {request_fun, request_count} = TestSupport.flunk_paystack_request_fun()
    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
    assert E2E.reload_payment_attempt!(attempt.id).status == "initialized"
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 0
  end

  test "callback restarts only recovery-exhausted manual review through server verification", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
      [attempt.id, "payment_verification_recovery_exhausted"]
    )

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    refute conn.resp_body =~ attempt.provider_reference
    assert E2E.reload_payment_attempt!(attempt.id).status == "verification_retry_queued"
    assert :counters.get(request_count, 1) == 0

    assert [%{args: args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert args == %{"payment_attempt_id" => attempt.id}
    assert :ok = perform_job(VerifyPaymentWorker, args)

    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert :counters.get(request_count, 1) == 1
  end

  test "callback preserves retry intent while an exhausted verify job is still active", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
      [attempt.id, "payment_verification_recovery_exhausted"]
    )

    assert {:ok, active_job} =
             VerifyPaymentWorker.new(%{"payment_attempt_id" => attempt.id})
             |> Oban.insert()

    Repo.update_all(
      from(job in Oban.Job, where: job.id == ^active_job.id),
      set: [state: "executing"]
    )

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
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

  test "callback does not restart unrelated manual-review payments", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = 'payment_state_conflict' WHERE id = $1",
      [attempt.id]
    )

    conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert conn.status == 200
    assert conn.resp_body =~ "We're checking your payment."
    assert E2E.reload_payment_attempt!(attempt.id).status == "manual_review"
    refute_enqueued(worker: VerifyPaymentWorker)
  end

  test "recovery-exhausted callback retry has one bounded verification cycle", %{
    event: event,
    offer: offer
  } do
    %{attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    Repo.query!(
      "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
      [attempt.id, "payment_verification_recovery_exhausted"]
    )

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.init_and_verify_request_fun(
          amount: attempt.amount_cents,
          currency: attempt.currency,
          provider_status: "pending"
        )
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)
    get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert [%{id: job_id, args: args}] = all_enqueued(worker: VerifyPaymentWorker)

    assert :ok =
             VerifyPaymentWorker.perform(%Oban.Job{
               args: args,
               attempt: 5,
               max_attempts: 5
             })

    Repo.query!("UPDATE oban_jobs SET state = 'completed' WHERE id = $1", [job_id])

    reviewed = E2E.reload_payment_attempt!(attempt.id)
    assert reviewed.status == "manual_review"
    assert reviewed.manual_review_reason == "payment_verification_recovery_retry_exhausted"
    assert :counters.get(request_count, 1) == 1

    get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})

    assert E2E.reload_payment_attempt!(attempt.id).status == "manual_review"
    refute_enqueued(worker: VerifyPaymentWorker)
    assert :counters.get(request_count, 1) == 1
  end

  test "callback and webhook races produce one verified payment and one fulfillment chain", %{
    event: event,
    offer: offer
  } do
    %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    body =
      TestSupport.charge_success_webhook_body(
        reference: attempt.provider_reference,
        provider_event_id: "evt-callback-race-#{System.unique_integer([:positive])}"
      )

    signature = TestSupport.sign_webhook_body(body)

    callback_task =
      Task.async(fn ->
        get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})
      end)

    webhook_task = Task.async(fn -> WebhookIngestion.ingest(body, signature) end)

    assert %{status: 200} = Task.await(callback_task)
    assert {:ok, :created, payment_event} = Task.await(webhook_task)

    assert :ok =
             perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

    assert [%{args: verify_args}] = all_enqueued(worker: VerifyPaymentWorker)
    assert verify_args["payment_attempt_id"] == attempt.id
    assert :ok = perform_job(VerifyPaymentWorker, verify_args)

    assert :counters.get(request_count, 1) == 1
    assert E2E.reload_payment_attempt!(attempt.id).status == "verified_success"
    assert E2E.reload_order!(order.id).status == "paid_verified"
    assert E2E.order_transition_count(order.id, "paid_verified") == 1
    assert length(all_enqueued(worker: PaidOrderFulfillmentWorker)) == 1

    if E2E.reload_payment_event!(payment_event.id).processing_status != "processed" do
      Repo.query!(
        "UPDATE oban_jobs SET state = 'completed' WHERE worker = $1 AND args->>'payment_attempt_id' = $2 AND state IN ('available', 'scheduled', 'retryable')",
        [inspect(VerifyPaymentWorker), to_string(attempt.id)]
      )

      Repo.query!(
        "UPDATE oban_jobs SET state = 'completed' WHERE worker = $1 AND args->>'payment_event_id' = $2 AND state IN ('available', 'scheduled', 'retryable')",
        [inspect(PaystackWebhookWorker), to_string(payment_event.id)]
      )

      Repo.query!(
        "UPDATE sales_payment_events SET inserted_at = $2 WHERE id = $1",
        [payment_event.id, DateTime.add(DateTime.utc_now(), -180, :second)]
      )

      assert {:ok, %{events_enqueued: 1}} = PaymentRecovery.sweep()
      assert :ok = perform_job(PaystackWebhookWorker, %{"payment_event_id" => payment_event.id})

      assert [%{args: replay_args}] = all_enqueued(worker: VerifyPaymentWorker)
      assert replay_args["payment_event_id"] == payment_event.id
      assert :ok = perform_job(VerifyPaymentWorker, replay_args)
    end

    assert E2E.reload_payment_event!(payment_event.id).processing_status == "processed"

    assert [%{args: fulfillment_args}] = all_enqueued(worker: PaidOrderFulfillmentWorker)
    assert :ok = perform_job(PaidOrderFulfillmentWorker, fulfillment_args)
    assert %{reserved_quantity: 0, consumed_quantity: 1} = E2E.inventory_snapshot!(offer.id)
    assert length(all_enqueued(worker: IssueTicketsWorker)) == 1
  end

  test "late-webhook recovery holds the order lock through callback retry and verification" do
    %{event: event, offer: offer, order: order, attempt: attempt, payment_event: payment_event} =
      committed_recovery_race_fixture!()

    parent = self()
    previous_hooks = Application.get_env(:fastcheck, :sales_payment_recovery_test_hooks, [])

    barrier = fn payment_attempt_id, loaded_attempt ->
      send(parent, {
        :webhook_attempt_reload_barrier,
        self(),
        payment_attempt_id,
        loaded_attempt.status,
        Repo.in_transaction?()
      })

      receive do
        :release_webhook_attempt_reload -> :ok
      after
        10_000 -> {:error, :webhook_attempt_reload_barrier_timeout}
      end
    end

    Application.put_env(
      :fastcheck,
      :sales_payment_recovery_test_hooks,
      Keyword.put(previous_hooks, :webhook_attempt_reload_barrier, barrier)
    )

    {request_fun, request_count} =
      TestSupport.counting_request_fun(
        TestSupport.verify_success_request_fun(amount: order.total_amount_cents)
      )

    Application.put_env(:fastcheck, :paystack_request_fun, request_fun)

    webhook_task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          PaystackWebhookWorker.perform(%Oban.Job{
            args: %{"payment_event_id" => payment_event.id}
          })
        end)
      end)

    Process.put(:payment_recovery_callback_race_task, nil)

    try do
      assert_receive {
                       :webhook_attempt_reload_barrier,
                       webhook_pid,
                       attempt_id,
                       "manual_review",
                       true
                     },
                     5_000

      assert webhook_pid == webhook_task.pid
      assert attempt_id == attempt.id

      callback_task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            conn = get(build_conn(), @callback_path, %{"reference" => attempt.provider_reference})
            {conn.status, conn.resp_body}
          end)
        end)

      Process.put(:payment_recovery_callback_race_task, callback_task)

      await_order_advisory_lock_waiters!(order.id, 1)
      assert is_nil(Task.yield(callback_task, 0))

      send(webhook_task.pid, :release_webhook_attempt_reload)
      assert :ok = Task.await(webhook_task, 10_000)

      assert {200, body} = Task.await(callback_task, 10_000)
      assert body =~ "We're checking your payment."

      assert [%{args: verify_args}] =
               all_enqueued(
                 worker: VerifyPaymentWorker,
                 args: %{"payment_attempt_id" => attempt.id}
               )

      assert verify_args["payment_event_id"] == payment_event.id

      assert :ok =
               Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                 VerifyPaymentWorker.perform(%Oban.Job{
                   args: verify_args,
                   attempt: 1,
                   max_attempts: 5
                 })
               end)

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               E2E.reload_payment_attempt!(attempt.id).status
             end) == "verified_success"

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               E2E.reload_payment_event!(payment_event.id).processing_status
             end) == "processed"

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               E2E.reload_order!(order.id).status
             end) == "paid_verified"

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               E2E.order_transition_count(order.id, "paid_verified")
             end) == 1

      assert committed_transition_count("PaymentAttempt", attempt.id, "verified_success") == 1

      assert committed_transition_count("PaymentAttempt", attempt.id, "verification_retry_queued") ==
               1

      assert committed_transition_id("PaymentAttempt", attempt.id, "verification_retry_queued") <
               committed_transition_id("PaymentAttempt", attempt.id, "verified_success")

      assert :counters.get(request_count, 1) == 1

      assert Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT count(*) FROM oban_jobs WHERE worker = $1 AND args->>'payment_attempt_id' = $2 AND state IN ('available', 'scheduled', 'executing', 'retryable')",
                 [inspect(PaidOrderFulfillmentWorker), to_string(attempt.id)]
               ).rows
               |> hd()
               |> hd()
             end) == 1
    after
      if Process.alive?(webhook_task.pid) do
        send(webhook_task.pid, :release_webhook_attempt_reload)
      end

      case Process.get(:payment_recovery_callback_race_task) do
        %Task{pid: callback_pid} = callback_task ->
          if Process.alive?(callback_pid), do: Task.shutdown(callback_task, :brutal_kill)

        _ ->
          :ok
      end

      Process.delete(:payment_recovery_callback_race_task)

      Task.shutdown(webhook_task, :brutal_kill)

      if previous_hooks == [],
        do: Application.delete_env(:fastcheck, :sales_payment_recovery_test_hooks),
        else:
          Application.put_env(
            :fastcheck,
            :sales_payment_recovery_test_hooks,
            previous_hooks
          )

      cleanup_committed_payment_fixture!(
        event.id,
        offer.id,
        order.id,
        attempt.id,
        payment_event.id
      )
    end
  end

  defp committed_recovery_race_fixture! do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      {event, offer} = E2E.setup_sales_event_offer!()
      %{order: order, attempt: attempt} = E2E.start_initialized_checkout!(event, offer)

      Repo.query!(
        "UPDATE sales_payment_attempts SET status = 'manual_review', manual_review_reason = $2 WHERE id = $1",
        [attempt.id, "payment_verification_recovery_exhausted"]
      )

      %{status: _status, event: payment_event} = E2E.ingest_paystack_success!(attempt)

      %{event: event, offer: offer, order: order, attempt: attempt, payment_event: payment_event}
    end)
  end

  defp await_order_advisory_lock_waiters!(order_id, expected_count) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    do_await_order_advisory_lock_waiters(order_id, expected_count, deadline)
  end

  defp do_await_order_advisory_lock_waiters(order_id, expected_count, deadline) do
    %{rows: [[waiter_count]]} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          """
          SELECT count(*)
          FROM pg_locks
          WHERE locktype = 'advisory'
            AND granted = false
            AND classid = 0::oid
            AND objid::bigint = $1::bigint
            AND objsubid = 1
          """,
          [order_id]
        )
      end)

    cond do
      waiter_count >= expected_count ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{expected_count} order advisory-lock waiters, saw #{waiter_count}")

      true ->
        Process.sleep(10)
        do_await_order_advisory_lock_waiters(order_id, expected_count, deadline)
    end
  end

  defp committed_transition_count(entity_type, entity_id, to_state) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.one!(
        from(transition in "sales_state_transitions",
          where:
            transition.entity_type == ^entity_type and
              transition.entity_id == ^to_string(entity_id) and transition.to_state == ^to_state,
          select: count(transition.id)
        )
      )
    end)
  end

  defp committed_transition_id(entity_type, entity_id, to_state) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.one!(
        from(transition in "sales_state_transitions",
          where:
            transition.entity_type == ^entity_type and
              transition.entity_id == ^to_string(entity_id) and transition.to_state == ^to_state,
          select: min(transition.id)
        )
      )
    end)
  end

  defp cleanup_committed_payment_fixture!(
         event_id,
         offer_id,
         order_id,
         attempt_id,
         payment_event_id
       ) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        conversation_id =
          Repo.one!(
            from(order in "sales_orders",
              where: order.id == ^order_id,
              select: order.sales_conversation_id
            )
          )

        session_id =
          Repo.one!(
            from(session in "sales_checkout_sessions",
              where: session.sales_order_id == ^order_id,
              select: session.id
            )
          )

        Repo.query!(
          "DELETE FROM oban_jobs WHERE args->>'payment_attempt_id' = $1 OR args->>'payment_event_id' = $2",
          [to_string(attempt_id), to_string(payment_event_id)]
        )

        Repo.query!(
          "DELETE FROM sales_state_transitions WHERE (entity_type = 'Order' AND entity_id = $1) OR (entity_type = 'PaymentAttempt' AND entity_id = $2) OR (entity_type = 'PaymentEvent' AND entity_id = $3)",
          [to_string(order_id), to_string(attempt_id), to_string(payment_event_id)]
        )

        Repo.query!(
          "DELETE FROM sales_state_transitions WHERE entity_type = 'CheckoutSession' AND entity_id = $1",
          [to_string(session_id)]
        )

        Repo.query!("DELETE FROM sales_payment_events WHERE id = $1", [payment_event_id])
        Repo.query!("DELETE FROM sales_payment_attempts WHERE id = $1", [attempt_id])
        Repo.query!("DELETE FROM sales_checkout_sessions WHERE sales_order_id = $1", [order_id])
        Repo.query!("DELETE FROM sales_order_lines WHERE sales_order_id = $1", [order_id])
        Repo.query!("DELETE FROM sales_orders WHERE id = $1", [order_id])

        if conversation_id do
          Repo.query!("DELETE FROM sales_conversations WHERE id = $1", [conversation_id])
        end

        Repo.query!("DELETE FROM sales_ticket_offers WHERE id = $1", [offer_id])
        Repo.query!("DELETE FROM events WHERE id = $1", [event_id])
      end)
    end)

    SalesCheckoutFixtures.flush_inventory_keys(offer_id)
    TestSupport.flush_webhook_dedupe_keys!()
  end
end
