defmodule FastCheck.Sales.Payments.PaymentRecovery do
  @moduledoc """
  Re-enqueues existing payment workers for unresolved Paystack records.

  Automatic provider polling is bounded by the configured recovery horizon.
  Attempts that outlive that budget enter the existing manual-review state so
  they remain visible and may only be restarted by an approved later trigger.
  This module does not contact Paystack or decide payment outcomes.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr
  import Ecto.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Payments.Paystack.Config, as: PaystackConfig
  alias FastCheck.Repo
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.VerifyPaymentWorker

  @provider_paystack "paystack"
  @recovery_exhausted_reason "payment_verification_recovery_exhausted"
  @recovery_retry_reason "payment_verification_recovery_retry"
  @recovery_retry_exhausted_reason "payment_verification_recovery_retry_exhausted"
  @live_verify_job_states ["available", "scheduled", "executing", "retryable"]

  @recoverable_attempt_statuses [
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verification_retry_queued"
  ]

  @horizon_attempt_statuses [
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started"
  ]

  @webhook_verifiable_attempt_statuses @recoverable_attempt_statuses ++
                                         [
                                           "verified_success"
                                         ]

  @recoverable_event_statuses ["stored", "processing_started", "unmatched", "failed"]

  @doc """
  Enqueues bounded batches of unresolved attempts and signed payment events.

  The attempt query uses the existing `(status, inserted_at)` index and returns
  at most the configured batch. Old attempts are retained for an explicit
  recovery-exhausted handoff; operator retry state is not aged by the original
  attempt insertion timestamp.
  """
  @spec sweep() :: {:ok, map()} | {:error, term()}
  def sweep do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    horizon_before = DateTime.add(now, -horizon_seconds(), :second)
    batch_size = batch_size()

    with {:ok, attempts} <- recoverable_attempts(stale_before, batch_size),
         {:ok, attempt_results} <- recover_attempts(attempts, horizon_before),
         {:ok, events} <- recoverable_events(stale_before, horizon_before, batch_size),
         {:ok, event_results} <- enqueue_events(events) do
      {:ok,
       %{
         attempts_enqueued: Enum.count(attempt_results, &(&1 in [:enqueued, :already_queued])),
         attempts_reviewed: Enum.count(attempt_results, &(&1 == :reviewed)),
         attempts_skipped: Enum.count(attempt_results, &(&1 == :skipped)),
         events_enqueued: Enum.count(event_results, &(&1 in [:enqueued, :already_queued])),
         events_skipped: Enum.count(event_results, &(&1 == :skipped))
       }}
    end
  end

  @doc """
  Enqueues verification for an unresolved Paystack attempt found by reference.

  A recovery-exhausted manual-review attempt may be restarted through the
  existing `queue_verification_retry` transition. Other manual-review and
  terminal states are safe no-ops so the public callback cannot retry them.
  """
  @spec enqueue_verification_by_reference(term()) ::
          {:ok, :enqueued | :already_queued | :not_found | :not_recoverable | :invalid_reference}
          | {:error, :enqueue_failed | :lookup_failed}
  def enqueue_verification_by_reference(reference) do
    with {:ok, normalized_reference} <- normalize_reference(reference),
         {:ok, attempt} <- find_attempt_by_reference(normalized_reference) do
      case attempt do
        nil ->
          {:ok, :not_found}

        %PaymentAttempt{id: payment_attempt_id} ->
          case callback_handoff(payment_attempt_id) do
            {:ok, result} -> {:ok, result}
            {:error, :enqueue_failed} -> {:error, :enqueue_failed}
            {:error, _reason} -> {:error, :lookup_failed}
          end
      end
    else
      {:error, :invalid_reference} -> {:ok, :invalid_reference}
      {:error, :lookup_failed} -> {:error, :lookup_failed}
    end
  end

  @doc """
  Prepares a matching attempt for a signed webhook handoff.

  The caller must run this inside the same Repo transaction that advances the
  PaymentEvent and inserts VerifyPaymentWorker. `:not_recoverable` tells the
  caller to close the event into manual review without retrying the attempt.
  """
  @spec prepare_webhook_attempt(integer()) ::
          {:ok, PaymentAttempt.t() | :deferred | :not_recoverable} | {:error, term()}
  def prepare_webhook_attempt(payment_attempt_id) when is_integer(payment_attempt_id) do
    if Repo.in_transaction?() do
      with {:ok, initial_attempt} <- required_attempt(payment_attempt_id),
           :ok <- lock_order(initial_attempt.sales_order_id),
           {:ok, attempt} <- required_attempt(payment_attempt_id),
           :ok <- webhook_attempt_reload_barrier(payment_attempt_id, attempt) do
        prepare_webhook_attempt_for(attempt)
      end
    else
      {:error, :transaction_required}
    end
  end

  defp prepare_webhook_attempt_for(attempt) do
    cond do
      attempt.status == "manual_review" and
          attempt.manual_review_reason == @recovery_exhausted_reason ->
        queue_recovery_exhausted_retry(attempt)

      verify_job_exists?(attempt.id) ->
        {:ok, :deferred}

      attempt.status in @webhook_verifiable_attempt_statuses or attempt.status == "initializing" ->
        prepare_trusted_trigger(attempt)

      true ->
        {:ok, :not_recoverable}
    end
  end

  @doc """
  Checks the bounded recovery horizon immediately before provider verification.

  Explicit operator retry state and verified-success idempotency work bypass the
  original attempt age. An old automatic job enters manual review without
  contacting Paystack.
  """
  @spec prepare_verification(integer(), keyword()) ::
          {:ok, :verify | :recovery_exhausted | :not_recoverable} | {:error, term()}
  def prepare_verification(payment_attempt_id, opts \\ []) when is_integer(payment_attempt_id) do
    event_id = Keyword.get(opts, :payment_event_id)

    with_attempt_lock(payment_attempt_id, fn attempt ->
      cond do
        attempt.status in ["verification_retry_queued", "verified_success"] ->
          {:ok, :verify}

        attempt.status in @recoverable_attempt_statuses and attempt_outside_horizon?(attempt) ->
          with {:ok, _result} <-
                 mark_recovery_exhausted_in_transaction(attempt, event_id, :verify_worker) do
            {:ok, :recovery_exhausted}
          end

        attempt.status in @recoverable_attempt_statuses ->
          {:ok, :verify}

        true ->
          {:ok, :not_recoverable}
      end
    end)
  end

  @doc """
  Moves an unresolved attempt to the existing recovery-exhausted review state.

  The sweep uses this after the automatic horizon when no live verification job
  remains. The worker uses it after its final retryable provider result and may
  pass the linked event so that an exhausted webhook event also leaves the
  automatic retry queue.
  """
  @spec mark_recovery_exhausted(integer(), keyword()) ::
          {:ok, :reviewed | :already_reviewed | :skipped} | {:error, term()}
  def mark_recovery_exhausted(payment_attempt_id, opts \\ [])
      when is_integer(payment_attempt_id) do
    event_id = Keyword.get(opts, :payment_event_id)
    require_no_live_job? = Keyword.get(opts, :require_no_live_job?, false)

    Repo.transaction(fn ->
      with {:ok, initial_attempt} <- required_attempt(payment_attempt_id),
           :ok <- lock_order(initial_attempt.sales_order_id),
           {:ok, attempt} <- required_attempt(payment_attempt_id),
           {:ok, result} <-
             mark_recovery_exhausted_in_transaction(
               attempt,
               event_id,
               Keyword.get(opts, :source, :sweep),
               require_no_live_job?
             ) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recoverable_attempts(stale_before, limit) do
    with {:ok, retry_attempts} <- orphaned_retry_attempts(limit) do
      remaining = limit - length(retry_attempts)

      if remaining == 0 do
        {:ok, retry_attempts}
      else
        stale_attempts(stale_before, remaining)
        |> case do
          {:ok, attempts} -> {:ok, retry_attempts ++ attempts}
          error -> error
        end
      end
    end
  end

  defp orphaned_retry_attempts(limit) do
    worker = inspect(VerifyPaymentWorker)

    ids =
      Repo.all(
        from attempt in "sales_payment_attempts",
          where: attempt.provider == @provider_paystack,
          where: attempt.status == "verification_retry_queued",
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM oban_jobs AS j WHERE j.queue = 'payments' AND j.worker = ? AND j.state IN ('available', 'scheduled', 'executing', 'retryable') AND j.args @> jsonb_build_object('payment_attempt_id', CAST(? AS bigint)))",
              ^worker,
              attempt.id
            ),
          order_by: [asc: attempt.inserted_at, asc: attempt.id],
          limit: ^limit,
          select: attempt.id
      )

    load_attempts(ids)
  end

  defp stale_attempts(_stale_before, 0), do: {:ok, []}

  defp stale_attempts(stale_before, limit) do
    ids =
      PaymentAttempt
      |> Query.filter(
        expr(
          provider == @provider_paystack and status in ^@horizon_attempt_statuses and
            inserted_at <= ^stale_before
        )
      )
      |> Query.sort(inserted_at: :asc, id: :asc)
      |> Query.limit(limit)
      |> Query.select([:id])
      |> Ash.read(authorize?: false)

    case ids do
      {:ok, attempts} -> load_attempts(Enum.map(attempts, & &1.id))
      error -> error
    end
  end

  defp load_attempts([]), do: {:ok, []}

  defp load_attempts(ids) do
    case PaymentAttempt
         |> Query.filter(expr(id in ^ids))
         |> Ash.read(authorize?: false) do
      {:ok, attempts} ->
        by_id = Map.new(attempts, &{&1.id, &1})
        {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}

      error ->
        error
    end
  end

  defp recoverable_events(stale_before, horizon_before, limit) do
    PaymentEvent
    |> Query.filter(
      expr(
        provider == @provider_paystack and signature_valid == true and
          processing_status in ^@recoverable_event_statuses and
          inserted_at <= ^stale_before and inserted_at >= ^horizon_before
      )
    )
    |> Query.sort(inserted_at: :asc, id: :asc)
    |> Query.limit(limit)
    |> Ash.read(authorize?: false)
  end

  defp recover_attempts(attempts, horizon_before) do
    enqueue_results(attempts, &recover_attempt(&1, horizon_before))
  end

  defp recover_attempt(%PaymentAttempt{status: "verification_retry_queued", id: id}, _horizon) do
    if verify_job_exists?(id), do: {:ok, :skipped}, else: enqueue_verification(id, :sweep)
  end

  defp recover_attempt(%PaymentAttempt{id: id, inserted_at: inserted_at}, horizon_before) do
    if DateTime.compare(inserted_at, horizon_before) == :lt do
      case mark_recovery_exhausted(id, require_no_live_job?: true, source: :sweep) do
        {:ok, :reviewed} -> {:ok, :reviewed}
        {:ok, :already_reviewed} -> {:ok, :skipped}
        {:ok, :skipped} -> {:ok, :skipped}
        {:error, reason} -> {:error, reason}
      end
    else
      enqueue_verification(id, :sweep)
    end
  end

  defp enqueue_events(events) do
    enqueue_results(events, &enqueue_event_if_attempt_is_unresolved/1)
  end

  defp enqueue_results(rows, enqueue_fun) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, results} ->
      case enqueue_fun.(row) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp enqueue_event_if_attempt_is_unresolved(
         %{provider_reference: reference, processing_status: status} = event
       )
       when not is_binary(reference) or reference == "" do
    if status in ["stored", "processing_started"] do
      enqueue_webhook_event(event.id)
    else
      {:ok, :skipped}
    end
  end

  defp enqueue_event_if_attempt_is_unresolved(event) do
    case find_attempt_by_reference(event.provider_reference) do
      {:ok, nil} ->
        enqueue_webhook_event(event.id)

      {:ok, %PaymentAttempt{status: status}} when status in @recoverable_attempt_statuses ->
        enqueue_webhook_event(event.id)

      {:ok, %PaymentAttempt{status: "verified_success"}} ->
        enqueue_webhook_event(event.id)

      {:ok, %PaymentAttempt{}} ->
        {:ok, :skipped}

      {:error, :lookup_failed} ->
        {:error, :lookup_failed}
    end
  end

  defp enqueue_verification(payment_attempt_id, source) do
    with_attempt_lock(payment_attempt_id, fn attempt ->
      if recoverable_attempt_status?(attempt.status) do
        enqueue_verification_if_absent(attempt, source)
      else
        {:ok, :skipped}
      end
    end)
  end

  defp callback_handoff(payment_attempt_id) do
    with_attempt_lock(payment_attempt_id, fn attempt ->
      cond do
        attempt.status in @recoverable_attempt_statuses ->
          if attempt_outside_horizon?(attempt),
            do: {:ok, :not_recoverable},
            else: enqueue_verification_if_absent(attempt, :callback)

        attempt.status == "verification_retry_queued" ->
          enqueue_verification_if_absent(attempt, :callback)

        attempt.status == "manual_review" and
            attempt.manual_review_reason == @recovery_exhausted_reason ->
          with {:ok, queued_attempt} <- queue_recovery_exhausted_retry(attempt) do
            insert_verify_job(%{"payment_attempt_id" => queued_attempt.id}, :callback, %{
              payment_attempt_id: queued_attempt.id
            })
          end

        true ->
          {:ok, :not_recoverable}
      end
    end)
  end

  defp prepare_trusted_trigger(attempt) do
    cond do
      attempt.status == "initializing" ->
        {:ok, :deferred}

      attempt.status == "verification_retry_queued" ->
        {:ok, attempt}

      attempt.status == "verified_success" ->
        {:ok, attempt}

      attempt_outside_horizon?(attempt) and attempt.status in @horizon_attempt_statuses ->
        case recovery_exhausted_transition(attempt) do
          {:ok, exhausted} -> queue_recovery_exhausted_retry(exhausted)
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, attempt}
    end
  end

  defp mark_recovery_exhausted_in_transaction(
         attempt,
         event_id,
         source,
         require_no_live_job? \\ false
       ) do
    cond do
      attempt.status == "manual_review" and
          attempt.manual_review_reason in [
            @recovery_exhausted_reason,
            @recovery_retry_exhausted_reason
          ] ->
        with :ok <- mark_event_recovery_exhausted(event_id) do
          {:ok, :already_reviewed}
        end

      attempt.status not in @recoverable_attempt_statuses ->
        {:ok, :skipped}

      require_no_live_job? and verify_job_exists?(attempt.id) ->
        {:ok, :skipped}

      true ->
        with {:ok, _reviewed} <- recovery_exhausted_transition(attempt),
             :ok <- mark_event_recovery_exhausted(event_id) do
          record_recovery_exhausted(attempt.id, source)
          {:ok, :reviewed}
        end
    end
  end

  defp with_attempt_lock(payment_attempt_id, fun) do
    Repo.transaction(fn ->
      case find_attempt_by_id(payment_attempt_id) do
        {:ok, nil} ->
          Repo.rollback(:payment_attempt_not_found)

        {:error, reason} ->
          Repo.rollback(reason)

        {:ok, initial_attempt} ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [initial_attempt.sales_order_id])

          case find_attempt_by_id(payment_attempt_id) do
            {:ok, nil} -> Repo.rollback(:payment_attempt_not_found)
            {:error, reason} -> Repo.rollback(reason)
            {:ok, attempt} -> run_attempt_operation(attempt, fun)
          end
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when reason in [:enqueue_failed, :payment_attempt_not_found] ->
        record_enqueue_failure(:callback, %{payment_attempt_id: payment_attempt_id})
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_attempt_operation(attempt, fun) do
    case fun.(attempt) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enqueue_verification_if_absent(attempt, source) do
    if verify_job_exists?(attempt.id) do
      {:ok, :already_queued}
    else
      insert_verify_job(%{"payment_attempt_id" => attempt.id}, source, %{
        payment_attempt_id: attempt.id
      })
    end
  end

  defp queue_recovery_exhausted_retry(attempt) do
    attempt
    |> Changeset.for_update(:queue_verification_retry, %{},
      reason: @recovery_exhausted_reason,
      actor: system_actor("payment_recovery_trigger")
    )
    |> Ash.update(authorize?: false)
  end

  defp recovery_exhausted_transition(attempt) do
    reason =
      if attempt.manual_review_reason in [
           @recovery_retry_reason,
           @recovery_retry_exhausted_reason
         ],
         do: @recovery_retry_exhausted_reason,
         else: @recovery_exhausted_reason

    attempt
    |> Changeset.for_update(
      :mark_manual_review,
      %{manual_review_reason: reason},
      reason: reason,
      actor: system_actor("payment_recovery")
    )
    |> Ash.update(authorize?: false)
  end

  defp mark_event_recovery_exhausted(nil), do: :ok

  defp mark_event_recovery_exhausted(payment_event_id) do
    case find_event_by_id(payment_event_id) do
      {:ok, nil} ->
        {:error, :payment_event_not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, %{processing_status: "processing_started"} = event} ->
        event
        |> Changeset.for_update(
          :mark_manual_review,
          %{last_processing_error: @recovery_exhausted_reason},
          actor: system_actor("payment_recovery")
        )
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _event} ->
        :ok
    end
  end

  defp verify_job_exists?(payment_attempt_id) do
    worker = inspect(VerifyPaymentWorker)

    Repo.exists?(
      from job in Oban.Job,
        where: job.queue == "payments",
        where: job.worker == ^worker,
        where:
          fragment(
            "? @> jsonb_build_object('payment_attempt_id', CAST(? AS bigint))",
            job.args,
            ^payment_attempt_id
          ),
        where: job.state in ^@live_verify_job_states,
        limit: 1
    )
  end

  defp insert_verify_job(args, source, metadata) do
    VerifyPaymentWorker.new(args)
    |> insert_job(source, metadata)
  end

  defp enqueue_webhook_event(payment_event_id) do
    PaystackWebhookWorker.new(%{"payment_event_id" => payment_event_id})
    |> insert_job(:sweep, %{payment_event_id: payment_event_id})
  end

  defp insert_job(job, source, metadata) do
    case Oban.insert(job) do
      {:ok, %Oban.Job{conflict?: true}} ->
        {:ok, :already_queued}

      {:ok, %Oban.Job{}} ->
        {:ok, :enqueued}

      {:error, _reason} ->
        record_enqueue_failure(source, metadata)
        {:error, :enqueue_failed}
    end
  rescue
    _error ->
      record_enqueue_failure(source, metadata)
      {:error, :enqueue_failed}
  end

  defp find_attempt_by_reference(reference) do
    PaymentAttempt
    |> Query.for_read(:get_by_provider_reference, %{
      provider: @provider_paystack,
      provider_reference: reference
    })
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :lookup_failed}
    end
  end

  defp find_attempt_by_id(id) do
    PaymentAttempt
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
  end

  defp required_attempt(id) do
    case find_attempt_by_id(id) do
      {:ok, %PaymentAttempt{} = attempt} -> {:ok, attempt}
      {:ok, nil} -> {:error, :payment_attempt_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_order(order_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])
    :ok
  end

  if Mix.env() == :test do
    defp webhook_attempt_reload_barrier(payment_attempt_id, attempt) do
      case Application.get_env(:fastcheck, :sales_payment_recovery_test_hooks, [])
           |> Keyword.get(:webhook_attempt_reload_barrier) do
        fun when is_function(fun, 2) -> fun.(payment_attempt_id, attempt)
        _ -> :ok
      end
    end
  else
    defp webhook_attempt_reload_barrier(_payment_attempt_id, _attempt), do: :ok
  end

  defp find_event_by_id(id) do
    PaymentEvent
    |> Query.for_read(:get_by_id, %{id: id})
    |> Ash.read_one(authorize?: false)
  end

  defp normalize_reference(reference) do
    case PaystackConfig.normalize_reference(reference) do
      {:ok, normalized_reference} -> {:ok, normalized_reference}
      {:error, _reason} -> {:error, :invalid_reference}
    end
  end

  defp recoverable_attempt_status?(status), do: status in @recoverable_attempt_statuses

  defp attempt_outside_horizon?(%PaymentAttempt{inserted_at: inserted_at}) do
    horizon_before = DateTime.add(DateTime.utc_now(), -horizon_seconds(), :second)
    DateTime.compare(inserted_at, horizon_before) == :lt
  end

  defp record_enqueue_failure(source, metadata) do
    :telemetry.execute(
      [:fastcheck, :sales, :payment, :recovery_enqueue_failed],
      %{count: 1},
      Map.merge(%{source: source, provider: @provider_paystack}, metadata)
    )
  end

  defp record_recovery_exhausted(payment_attempt_id, source) do
    :telemetry.execute(
      [:fastcheck, :sales, :payment, :recovery_exhausted],
      %{count: 1},
      %{payment_attempt_id: payment_attempt_id, source: source}
    )
  end

  defp system_actor(actor_id), do: %{actor_type: :system, actor_id: actor_id}

  defp stale_after_seconds do
    positive_config(:sales_payment_recovery_stale_after_seconds, 120)
  end

  defp horizon_seconds do
    positive_config(:sales_payment_recovery_horizon_seconds, 900)
  end

  defp batch_size do
    positive_config(:sales_payment_recovery_batch_size, 200)
  end

  defp positive_config(key, default) do
    case Application.get_env(:fastcheck, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
