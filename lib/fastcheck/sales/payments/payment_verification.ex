defmodule FastCheck.Sales.Payments.PaymentVerification do
  @moduledoc """
  Approved Sales Paystack payment verification boundary.

  Verifies provider transactions server-side via `TransactionVerifier`, classifies
  outcomes via `PaymentOutcomes`, and applies safe transitions via
  `PaymentOutcomeHandler`. Does not issue tickets or trust webhook payloads alone.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Correlation
  alias FastCheck.Payments.Paystack.Error, as: PaystackError
  alias FastCheck.Payments.Paystack.TransactionVerifier
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.PaymentOutcomeHandler
  alias FastCheck.Sales.Payments.PaymentOutcomes

  @type verify_result ::
          :verified
          | :idempotent
          | :mismatch
          | :failed
          | :manual_review
          | :late_payment_recovered
          | :late_payment_manual_review

  @spec verify_attempt(integer(), keyword()) ::
          {:ok, verify_result()}
          | {:error, :retryable | atom() | PaystackError.t()}
  def verify_attempt(payment_attempt_id, opts \\ []) when is_integer(payment_attempt_id) do
    context = build_context(opts)

    with {:ok, attempt} <- load_attempt(payment_attempt_id),
         order <- order_from_attempt(attempt),
         {:ok, session} <- load_checkout_session(attempt),
         {:ok, event} <- maybe_load_event(opts) do
      if attempt.status == "verified_success" do
        PaymentOutcomeHandler.apply_idempotent_verified(attempt, order, session, event, context)
      else
        do_verify(attempt, order, session, event, context)
      end
    end
  end

  defp build_context(opts) do
    correlation_id =
      Correlation.ensure_correlation_id(%{
        correlation_id: Keyword.get(opts, :correlation_id),
        request_id: Keyword.get(opts, :request_id)
      })

    %{
      actor: %{actor_type: :system, actor_id: "payment_verification"},
      correlation_id: correlation_id,
      transition_metadata: %{
        provider_reference: Keyword.get(opts, :provider_reference)
      }
    }
  end

  defp load_attempt(id) do
    case PaymentAttempt
         |> Query.for_read(:get_by_id, %{id: id})
         |> Ash.Query.load(order: :checkout_session)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :payment_attempt_not_found}
      {:ok, attempt} -> {:ok, attempt}
      {:error, error} -> {:error, error}
    end
  end

  defp load_order(order_id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: order_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, error} -> {:error, error}
    end
  end

  defp load_checkout_session(%PaymentAttempt{order: %{checkout_session: session}})
       when not is_nil(session),
       do: {:ok, session}

  defp load_checkout_session(%PaymentAttempt{sales_order_id: order_id}) do
    case CheckoutSession
         |> Query.filter(expr(sales_order_id == ^order_id))
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :checkout_session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, error} -> {:error, error}
    end
  end

  defp order_from_attempt(%PaymentAttempt{order: order}) when not is_nil(order), do: order

  defp order_from_attempt(%PaymentAttempt{sales_order_id: order_id}) do
    case load_order(order_id) do
      {:ok, order} -> order
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_load_event(opts) do
    case Keyword.get(opts, :payment_event_id) do
      nil ->
        {:ok, nil}

      event_id ->
        case PaymentEvent
             |> Query.for_read(:get_by_id, %{id: event_id})
             |> Ash.read_one(authorize?: false) do
          {:ok, nil} -> {:error, :payment_event_not_found}
          {:ok, event} -> {:ok, event}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp do_verify(attempt, order, session, event, context) do
    context =
      put_in(context.transition_metadata[:provider_reference], attempt.provider_reference)

    case mark_verification_started(attempt, context) do
      {:ok, attempt} ->
        case call_paystack_verify(attempt, context) do
          {:ok, verify_result} ->
            apply_verify_result(attempt, order, session, event, verify_result, context)

          {:error, :retryable} ->
            {:error, :retryable}

          {:error, error} ->
            finalize_verifier_error(attempt, event, error, context)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_verification_started(attempt, context) do
    case attempt
         |> Changeset.for_update(:mark_verification_started, %{}, actor: context.actor)
         |> Ash.update(authorize?: false, context: context) do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> {:error, error}
    end
  end

  defp call_paystack_verify(attempt, context) do
    correlation_opts = [correlation_id: context.correlation_id]

    case TransactionVerifier.verify(attempt.provider_reference, correlation_opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %PaystackError{retryable?: true}} ->
        {:error, :retryable}

      {:error, %PaystackError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_verify_result(attempt, order, session, event, verify_result, context) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order.id])

      attempt = reload_attempt!(attempt.id)
      order = reload_order!(order.id)
      session = reload_session!(session.id)

      case PaymentOutcomes.classify_provider_result(verify_result, attempt, order, session) do
        {:error, :retryable} ->
          Repo.rollback(:retryable)

        {:error, reason} ->
          Repo.rollback(reason)

        {:ok, outcome, attrs} ->
          case PaymentOutcomeHandler.apply(
                 outcome,
                 attrs,
                 attempt,
                 order,
                 session,
                 event,
                 context
               ) do
            {:ok, result} -> normalize_handler_result(result)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> normalize_transaction_result()
  end

  defp normalize_handler_result(:verified), do: :verified
  defp normalize_handler_result(:late_payment_recovered), do: :verified
  defp normalize_handler_result(:late_payment_manual_review), do: :manual_review
  defp normalize_handler_result(other), do: other

  defp finalize_verifier_error(attempt, event, error, context) do
    attrs = verifier_error_attrs(error)

    with {:ok, _attempt} <-
           attempt
           |> Changeset.for_update(:mark_verification_failed, attrs, actor: context.actor)
           |> Ash.update(authorize?: false, context: context),
         :ok <- maybe_mark_event_failed(event, attrs, context) do
      :telemetry.execute(
        [:fastcheck, :sales, :payment, :failed],
        %{count: 1},
        %{payment_attempt_id: attempt.id, verifier_error: true}
        |> Correlation.operational_metadata()
        |> Map.new()
      )

      {:ok, :failed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verifier_error_attrs(%PaystackError{type: type, message: message}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      failure_code: "verifier_#{type}",
      failure_message: message,
      last_verified_at: now
    }
  end

  defp verifier_error_attrs(reason) when is_atom(reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      failure_code: "verifier_#{reason}",
      failure_message: Atom.to_string(reason),
      last_verified_at: now
    }
  end

  defp verifier_error_attrs(reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      failure_code: "verifier_error",
      failure_message: inspect(reason),
      last_verified_at: now
    }
  end

  defp maybe_mark_event_failed(nil, _attrs, _context), do: :ok

  defp maybe_mark_event_failed(%{processing_status: "failed"}, _attrs, _context), do: :ok

  defp maybe_mark_event_failed(%{processing_status: "processing_started"} = event, attrs, context) do
    error_message = Map.get(attrs, :failure_message) || "verification_failed"

    case event
         |> Changeset.for_update(
           :mark_failed,
           %{last_processing_error: error_message},
           actor: context.actor
         )
         |> Ash.update(authorize?: false, context: context) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_event_failed(_event, _attrs, _context), do: :ok

  defp reload_attempt!(id), do: load_attempt(id) |> unwrap!
  defp reload_order!(id), do: load_order(id) |> unwrap!

  defp reload_session!(id) do
    case CheckoutSession
         |> Query.for_read(:get_by_id, %{id: id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> Repo.rollback(:checkout_session_not_found)
      {:ok, session} -> session
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp unwrap!({:ok, record}), do: record
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, :retryable}), do: {:error, :retryable}
  defp normalize_transaction_result({:error, {:rollback, :retryable}}), do: {:error, :retryable}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
