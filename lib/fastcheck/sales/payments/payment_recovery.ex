defmodule FastCheck.Sales.Payments.PaymentRecovery do
  @moduledoc """
  Re-enqueues existing payment workers for stale unresolved Paystack records.

  This module does not contact Paystack or decide payment outcomes. All
  verification remains in `PaymentVerification`.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Query
  alias FastCheck.Payments.Paystack.Config, as: PaystackConfig
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.VerifyPaymentWorker

  @provider_paystack "paystack"

  @recoverable_attempt_statuses [
    "initialized",
    "authorization_url_sent",
    "webhook_received",
    "verification_started",
    "verification_retry_queued"
  ]

  @recoverable_event_statuses ["stored", "processing_started", "unmatched", "failed"]

  @doc """
  Enqueues bounded batches of stale payment attempts and signed payment events.

  Attempts and events are selected by their existing `(status, inserted_at)`
  indexes. A single sweep retains at most one configured batch from each stream
  in memory and inserts jobs sequentially into the existing payments queue.
  """
  @spec sweep() :: {:ok, map()} | {:error, term()}
  def sweep do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale_before = DateTime.add(now, -stale_after_seconds(), :second)
    horizon_before = DateTime.add(now, -horizon_seconds(), :second)
    batch_size = batch_size()

    with {:ok, attempts} <- stale_attempts(stale_before, horizon_before, batch_size),
         {:ok, attempt_results} <- enqueue_attempts(attempts),
         {:ok, events} <- recoverable_events(stale_before, horizon_before, batch_size),
         {:ok, event_results} <- enqueue_events(events) do
      {:ok,
       %{
         attempts_enqueued: Enum.count(attempt_results, &(&1 == :enqueued)),
         events_enqueued: Enum.count(event_results, &(&1 == :enqueued)),
         events_skipped: Enum.count(event_results, &(&1 == :skipped))
       }}
    end
  end

  @doc """
  Enqueues verification for an unresolved Paystack attempt found by its reference.

  The reference is normalized before lookup. Unknown and terminal references are
  safe no-ops so a public callback cannot learn which payments exist.
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

        %PaymentAttempt{status: status} = payment_attempt ->
          if recoverable_attempt_status?(status) do
            enqueue_verification(payment_attempt.id, :callback)
          else
            {:ok, :not_recoverable}
          end
      end
    else
      {:error, :invalid_reference} -> {:ok, :invalid_reference}
      {:error, :lookup_failed} -> {:error, :lookup_failed}
    end
  end

  defp stale_attempts(stale_before, horizon_before, limit) do
    PaymentAttempt
    |> Query.filter(
      expr(
        provider == @provider_paystack and status in ^@recoverable_attempt_statuses and
          inserted_at <= ^stale_before and inserted_at >= ^horizon_before
      )
    )
    |> Query.sort(inserted_at: :asc, id: :asc)
    |> Query.limit(limit)
    |> Ash.read(authorize?: false)
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

  defp enqueue_attempts(attempts) do
    enqueue_results(attempts, fn attempt -> enqueue_verification(attempt.id, :sweep) end)
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
    VerifyPaymentWorker.new(%{"payment_attempt_id" => payment_attempt_id})
    |> insert_job(source, %{payment_attempt_id: payment_attempt_id})
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

  defp normalize_reference(reference) do
    case PaystackConfig.normalize_reference(reference) do
      {:ok, normalized_reference} -> {:ok, normalized_reference}
      {:error, _reason} -> {:error, :invalid_reference}
    end
  end

  defp recoverable_attempt_status?(status), do: status in @recoverable_attempt_statuses

  defp record_enqueue_failure(source, metadata) do
    :telemetry.execute(
      [:fastcheck, :sales, :payment, :recovery_enqueue_failed],
      %{count: 1},
      Map.merge(%{source: source, provider: @provider_paystack}, metadata)
    )
  end

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
