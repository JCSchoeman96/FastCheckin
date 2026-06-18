defmodule FastCheck.Sales.Payments.PaymentVerification do
  @moduledoc """
  Approved Sales Paystack payment verification boundary.

  Verifies provider transactions server-side via `TransactionVerifier`, compares
  results to durable local state, and applies named Ash transitions. Does not
  issue tickets, mutate inventory, or trust webhook payloads as proof of payment.
  """

  require Logger

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

  @payable_order_statuses ~w(awaiting_payment payment_pending paid_unverified)
  @eligible_session_statuses ~w(payment_link_sent payment_started)
  @terminal_failed_provider_statuses ~w(failed abandoned reversed)

  @type verify_result :: :verified | :idempotent | :mismatch | :failed | :manual_review

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
        handle_verified_success_idempotent(attempt, order, session, event, context)
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

  defp handle_verified_success_idempotent(_attempt, _order, _session, nil, _context) do
    emit_telemetry(:verified, %{idempotent: true})
    {:ok, :idempotent}
  end

  defp handle_verified_success_idempotent(attempt, order, session, event, context) do
    _ = maybe_mark_event_processed(event, context)

    emit_telemetry(:verified, %{
      idempotent: true,
      payment_attempt_id: attempt.id,
      order_id: order.id,
      checkout_session_id: session.id
    })

    {:ok, :idempotent}
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

      case classify_verify_result(verify_result, attempt, order) do
        {:ok, :success, attrs} ->
          finalize_success(attempt, order, session, event, attrs, context)

        {:ok, :amount_mismatch, attrs} ->
          finalize_mismatch(attempt, event, :mark_verified_amount_mismatch, attrs, context)

        {:ok, :currency_mismatch, attrs} ->
          finalize_mismatch(attempt, event, :mark_verified_currency_mismatch, attrs, context)

        {:ok, :reference_mismatch, attrs} ->
          finalize_manual_review(attempt, event, attrs, context)

        {:ok, :provider_failed, attrs} ->
          finalize_provider_failed(attempt, event, attrs, context)

        {:error, :retryable} ->
          Repo.rollback(:retryable)

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp classify_verify_result(result, attempt, order) do
    provider_status = normalize_status(result.provider_status)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base_attrs = %{
      provider_status: result.provider_status,
      last_verified_at: now,
      raw_verify_response: result.safe_data || %{}
    }

    cond do
      provider_status != "success" and provider_status in @terminal_failed_provider_statuses ->
        {:ok, :provider_failed,
         Map.merge(base_attrs, %{
           failure_code: "provider_status_#{provider_status}",
           failure_message: "Paystack reported #{provider_status}"
         })}

      provider_status != "success" ->
        {:error, :retryable}

      reference_mismatch?(result, attempt) ->
        {:ok, :reference_mismatch,
         Map.merge(base_attrs, %{
           manual_review_reason: "provider_reference_mismatch",
           failure_code: "reference_mismatch",
           failure_message: "Provider reference mismatch"
         })}

      amount_mismatch?(result, attempt, order) ->
        {:ok, :amount_mismatch, base_attrs}

      currency_mismatch?(result, attempt, order) ->
        {:ok, :currency_mismatch, base_attrs}

      true ->
        paid_at = parse_paid_at(result.paid_at) || now

        {:ok, :success,
         Map.merge(base_attrs, %{
           provider_paid_at: paid_at,
           verified_at: now
         })}
    end
  end

  defp finalize_success(attempt, order, session, event, attrs, context) do
    with {:ok, attempt} <- update_attempt(attempt, :mark_verified_success, attrs, context),
         {:ok, result} <- maybe_mark_order_and_session_paid(attempt, order, session, context),
         :ok <- maybe_mark_event_processed(event, context) do
      emit_telemetry(:verified, %{
        payment_attempt_id: attempt.id,
        order_id: order.id,
        paid: result == :paid
      })

      :verified
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_mark_order_and_session_paid(_attempt, order, session, context) do
    if checkout_eligible?(session) and order_eligible?(order) do
      with {:ok, _order} <-
             order
             |> Changeset.for_update(:mark_paid_verified, %{}, actor: context.actor)
             |> Ash.update(authorize?: false, context: context),
           {:ok, _session} <-
             session
             |> Changeset.for_update(:mark_paid, %{}, actor: context.actor)
             |> Ash.update(authorize?: false, context: context) do
        {:ok, :paid}
      end
    else
      {:ok, :verified_only}
    end
  end

  defp finalize_mismatch(attempt, event, action, attrs, context) do
    with {:ok, _attempt} <- update_attempt(attempt, action, attrs, context),
         :ok <- maybe_mark_event_processed(event, context) do
      emit_telemetry(:mismatch, %{payment_attempt_id: attempt.id, action: action})
      :mismatch
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finalize_manual_review(attempt, event, attrs, context) do
    attrs = Map.take(attrs, [:failure_code, :failure_message, :manual_review_reason])

    with {:ok, _attempt} <-
           attempt
           |> Changeset.for_update(
             :mark_manual_review,
             attrs,
             actor: context.actor
           )
           |> Ash.update(authorize?: false, context: context),
         :ok <- maybe_mark_event_processed(event, context) do
      emit_telemetry(:mismatch, %{payment_attempt_id: attempt.id, action: :manual_review})
      :manual_review
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finalize_provider_failed(attempt, event, attrs, context) do
    attrs =
      Map.take(attrs, [:provider_status, :failure_code, :failure_message, :last_verified_at])

    with {:ok, _attempt} <- update_attempt(attempt, :mark_verification_failed, attrs, context),
         :ok <- maybe_mark_event_processed(event, context) do
      emit_telemetry(:failed, %{payment_attempt_id: attempt.id})
      :failed
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp finalize_verifier_error(attempt, event, error, context) do
    attrs = verifier_error_attrs(error)

    with {:ok, _attempt} <- update_attempt(attempt, :mark_verification_failed, attrs, context),
         :ok <- maybe_mark_event_failed(event, attrs, context) do
      emit_telemetry(:failed, %{payment_attempt_id: attempt.id, verifier_error: true})
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

  defp update_attempt(attempt, action, attrs, context) do
    attempt
    |> Changeset.for_update(action, attrs, actor: context.actor)
    |> Ash.update(authorize?: false, context: context)
  end

  defp maybe_mark_event_processed(nil, _context), do: :ok

  defp maybe_mark_event_processed(%{processing_status: "processed"}, _context), do: :ok

  defp maybe_mark_event_processed(event, context) do
    case event
         |> Changeset.for_update(:mark_processed, %{}, actor: context.actor)
         |> Ash.update(authorize?: false, context: context) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
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

  defp checkout_eligible?(session) do
    session.status in @eligible_session_statuses
  end

  defp order_eligible?(order) do
    order.status in @payable_order_statuses
  end

  defp reference_mismatch?(result, attempt) do
    case normalize_provider_reference(result.provider_reference) do
      nil ->
        true

      provider_reference ->
        provider_reference != normalize_provider_reference(attempt.provider_reference)
    end
  end

  defp normalize_provider_reference(reference) when is_binary(reference) do
    reference = String.trim(reference)
    if reference == "", do: nil, else: reference
  end

  defp normalize_provider_reference(_reference), do: nil

  defp amount_mismatch?(result, attempt, order) do
    provider_amount = normalize_amount(result.amount)
    provider_amount != attempt.amount_cents or provider_amount != order.total_amount_cents
  end

  defp currency_mismatch?(result, attempt, order) do
    provider_currency = normalize_currency(result.currency)

    provider_currency != normalize_currency(attempt.currency) or
      provider_currency != normalize_currency(order.currency)
  end

  defp normalize_amount(amount) when is_integer(amount), do: amount

  defp normalize_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp normalize_amount(_), do: nil

  defp normalize_currency(currency) when is_binary(currency), do: String.upcase(currency)
  defp normalize_currency(_), do: nil

  defp normalize_status(status) when is_binary(status), do: String.downcase(status)
  defp normalize_status(_), do: "unknown"

  defp parse_paid_at(nil), do: nil

  defp parse_paid_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_paid_at(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  defp parse_paid_at(_), do: nil

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

  defp emit_telemetry(kind, metadata) do
    event =
      case kind do
        :verified -> [:fastcheck, :sales, :payment, :verified]
        :mismatch -> [:fastcheck, :sales, :payment, :mismatch]
        :failed -> [:fastcheck, :sales, :payment, :failed]
      end

    :telemetry.execute(
      event,
      %{count: 1},
      metadata |> Correlation.operational_metadata() |> Map.new()
    )
  end
end
