defmodule FastCheck.Sales.Payments.PaystackWebhookWorker do
  @moduledoc """
  Oban worker for Paystack webhook follow-up after ingestion.

  Signed-event recovery, PaymentEvent advancement, and VerifyPaymentWorker
  handoff share one Repo transaction. The order advisory lock stays held until
  that transaction commits. Transaction verification runs in the verify worker.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:payment_event_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Correlation
  alias FastCheck.Repo
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaymentRecovery
  alias FastCheck.Sales.Payments.VerifyPaymentWorker

  @provider_paystack "paystack"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payment_event_id" => payment_event_id}}) do
    payment_event_id = normalize_id(payment_event_id)

    Repo.transaction(fn ->
      case load_event(payment_event_id) do
        {:ok, event} ->
          emit_webhook_received_telemetry(event)

          case handoff_verification(event) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: {:error, :invalid_args}

  defp emit_webhook_received_telemetry(event) do
    metadata =
      Correlation.operational_metadata(%{
        payment_event_id: event.id,
        provider: event.provider,
        event_type: event.event_type,
        status: event.processing_status
      })
      |> Map.new()

    :telemetry.execute(
      [:fastcheck, :sales, :payment, :webhook_received],
      %{count: 1},
      metadata
    )
  end

  defp handoff_verification(%{signature_valid: true, processing_status: "processed"}), do: :ok
  defp handoff_verification(%{signature_valid: true, processing_status: "duplicate"}), do: :ok

  defp handoff_verification(%{signature_valid: true} = event) do
    case find_payment_attempt(event) do
      {:ok, attempt} ->
        atomic_handoff_with_attempt(event, attempt)

      {:error, :not_found} ->
        atomic_handoff_unmatched(event)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handoff_verification(_event), do: :ok

  defp atomic_handoff_with_attempt(event, %PaymentAttempt{id: payment_attempt_id}) do
    case PaymentRecovery.prepare_webhook_attempt(payment_attempt_id) do
      {:ok, handoff} ->
        with {:ok, current_event} <- load_event(event.id) do
          if current_event.processing_status in ["processed", "duplicate"] do
            :ok
          else
            handoff_event(current_event, handoff)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handoff_event(event, :not_recoverable), do: mark_event_not_recoverable(event)

  defp handoff_event(event, attempt_handoff) do
    action =
      if event.processing_status in ["unmatched", "failed", "manual_review"],
        do: :retry_processing,
        else: :mark_processing_started

    case update_event(event, action) do
      {:ok, _updated_event} -> insert_verification_handoff(event, attempt_handoff)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_verification_handoff(_event, :deferred), do: :ok

  defp insert_verification_handoff(
         %{id: event_id},
         %PaymentAttempt{id: payment_attempt_id, provider_reference: provider_reference}
       ) do
    case VerifyPaymentWorker.new(%{
           "payment_event_id" => event_id,
           "payment_attempt_id" => payment_attempt_id,
           "provider_reference" => provider_reference
         })
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_event_not_recoverable(%{processing_status: "manual_review"}), do: :ok

  defp mark_event_not_recoverable(event) do
    action =
      if event.processing_status in ["unmatched", "failed"],
        do: :retry_processing,
        else: :mark_processing_started

    with {:ok, updated_event} <- update_event(event, action),
         {:ok, _reviewed_event} <- mark_event_not_recoverable_state(updated_event) do
      :ok
    end
  end

  defp atomic_handoff_unmatched(event) do
    attrs = %{last_processing_error: "no_matching_payment_attempt"}

    event
    |> Changeset.for_update(:mark_unmatched, attrs, actor: system_actor())
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _updated_event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_event(event, action) do
    event
    |> Changeset.for_update(action, %{}, actor: system_actor())
    |> Ash.update(authorize?: false)
  end

  defp mark_event_not_recoverable_state(event) do
    event
    |> Changeset.for_update(
      :mark_manual_review,
      %{last_processing_error: "payment_attempt_not_recoverable"},
      actor: system_actor()
    )
    |> Ash.update(authorize?: false)
  end

  defp find_payment_attempt(%{provider_reference: ref}) when is_binary(ref) and ref != "" do
    case PaymentAttempt
         |> Query.for_read(:get_by_provider_reference, %{
           provider: @provider_paystack,
           provider_reference: ref
         })
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_payment_attempt(_event), do: {:error, :not_found}

  defp load_event(payment_event_id) do
    PaymentEvent
    |> Query.filter(expr(id == ^payment_event_id))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, :payment_event_not_found}
      {:ok, event} -> {:ok, event}
      {:error, error} -> {:error, error}
    end
  end

  defp system_actor, do: %{actor_type: :system, actor_id: "paystack_webhook_worker"}

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
end
