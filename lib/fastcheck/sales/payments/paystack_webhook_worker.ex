defmodule FastCheck.Sales.Payments.PaystackWebhookWorker do
  @moduledoc """
  Oban worker for Paystack webhook follow-up after ingestion.

  VS-07B atomically marks `PaymentEvent` processing state and enqueues
  `VerifyPaymentWorker`. Transaction verification runs in the verify worker.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:payment_event_id]]

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias Ecto.Multi
  alias FastCheck.Observability.Correlation
  alias FastCheck.Repo
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.VerifyPaymentWorker

  @provider_paystack "paystack"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payment_event_id" => payment_event_id}}) do
    payment_event_id = normalize_id(payment_event_id)

    with {:ok, event} <- load_event(payment_event_id) do
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

      handoff_verification(event)
    end
  end

  def perform(_job), do: {:error, :invalid_args}

  defp handoff_verification(%{processing_status: "processed"}), do: :ok
  defp handoff_verification(%{processing_status: "duplicate"}), do: :ok

  defp handoff_verification(event) do
    case find_payment_attempt(event) do
      {:ok, attempt} ->
        atomic_handoff_with_attempt(event, attempt)

      {:error, :not_found} ->
        atomic_handoff_unmatched(event)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_handoff_with_attempt(event, attempt) do
    action =
      if event.processing_status == "unmatched",
        do: :retry_processing,
        else: :mark_processing_started

    Multi.new()
    |> Multi.run(:payment_event, fn _repo, _changes ->
      update_event(event, action)
    end)
    |> Multi.run(:verify_job, fn _repo, _changes ->
      VerifyPaymentWorker.new(%{
        "payment_event_id" => event.id,
        "payment_attempt_id" => attempt.id,
        "provider_reference" => attempt.provider_reference
      })
      |> Oban.insert()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp atomic_handoff_unmatched(event) do
    Multi.new()
    |> Multi.run(:payment_event, fn _repo, _changes ->
      attrs = %{last_processing_error: "no_matching_payment_attempt"}

      event
      |> Changeset.for_update(:mark_unmatched, attrs, actor: system_actor())
      |> Ash.update(authorize?: false)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp update_event(event, action) do
    event
    |> Changeset.for_update(action, %{}, actor: system_actor())
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
