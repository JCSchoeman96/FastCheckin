defmodule FastCheck.Sales.Payments.PaymentOutcomeHandler do
  @moduledoc """
  Applies Sales payment outcomes after Paystack verification classification.

  Mutates PaymentAttempt, Order, CheckoutSession, and PaymentEvent through named
  Ash actions only. Late-payment inventory recovery uses ReservationLedger with
  explicit compensation when Postgres transitions fail after Redis reserve.
  """

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Correlation
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.PaymentEvent
  alias FastCheck.Sales.Payments.LatePaymentRecovery
  alias FastCheck.Sales.Payments.OutcomeBroadcast
  alias FastCheck.Sales.Payments.PaymentFailureReason, as: Reasons
  alias FastCheck.Sales.Payments.PaymentOutcomes

  @type apply_result ::
          :verified
          | :idempotent
          | :mismatch
          | :manual_review
          | :failed
          | :late_payment_recovered
          | :late_payment_manual_review

  @doc """
  Applies a classified payment outcome inside the caller's advisory-locked transaction.

  Returns `{:ok, result}` on success or `{:error, reason}` to trigger rollback.
  """
  @spec apply(
          PaymentOutcomes.outcome(),
          map(),
          PaymentAttempt.t(),
          Order.t(),
          CheckoutSession.t(),
          PaymentEvent.t() | nil,
          map()
        ) :: {:ok, apply_result()} | {:error, term()}
  def apply(outcome, attrs, attempt, order, session, event, context) do
    metadata = build_metadata(outcome, attrs, attempt, order, session, event, context)

    case outcome do
      :verified_active_checkout ->
        apply_verified_active(attempt, order, session, event, attrs, context, metadata)

      :late_payment_recovery_required ->
        apply_late_payment_recovery(attempt, order, session, event, attrs, context, metadata)

      :duplicate_already_verified ->
        apply_duplicate(attempt, order, session, event, attrs, context, metadata)

      :amount_mismatch ->
        apply_mismatch(
          attempt,
          order,
          session,
          event,
          :mark_verified_amount_mismatch,
          attrs,
          context,
          metadata
        )

      :currency_mismatch ->
        apply_mismatch(
          attempt,
          order,
          session,
          event,
          :mark_verified_currency_mismatch,
          attrs,
          context,
          metadata
        )

      :reference_mismatch ->
        apply_reference_mismatch(attempt, order, session, event, attrs, context, metadata)

      :provider_failed ->
        apply_provider_failed(attempt, event, attrs, context, metadata)

      :manual_review_required ->
        apply_manual_review_all(attempt, order, session, event, attrs, context, metadata)

      :provider_pending_or_abandoned ->
        {:error, :retryable}
    end
  end

  @doc """
  Idempotent handling when PaymentAttempt is already verified_success.
  """
  @spec apply_idempotent_verified(
          PaymentAttempt.t(),
          Order.t(),
          CheckoutSession.t(),
          PaymentEvent.t() | nil,
          map()
        ) :: {:ok, :idempotent}
  def apply_idempotent_verified(attempt, order, session, event, context) do
    _ = finalize_event_processed(event, context)

    emit_payment_telemetry(:verified, %{
      idempotent: true,
      payment_attempt_id: attempt.id,
      order_id: order.id,
      checkout_session_id: session.id
    })

    OutcomeBroadcast.broadcast(:duplicate_ignored, %{
      payment_attempt_id: attempt.id,
      order_id: order.id,
      checkout_session_id: session.id,
      reason_code: Reasons.payment_duplicate_suspicious(),
      correlation_id: context.correlation_id
    })

    {:ok, :idempotent}
  end

  defp apply_verified_active(attempt, order, session, event, attrs, context, metadata) do
    with {:ok, _attempt} <- update_attempt(attempt, :mark_verified_success, attrs, context),
         {:ok, _} <- mark_order_and_session_paid(order, session, context),
         :ok <- finalize_event_processed(event, context) do
      emit_payment_telemetry(:verified, Map.put(metadata, :paid, true))
      {:ok, :verified}
    end
  end

  defp apply_late_payment_recovery(attempt, order, session, event, attrs, context, metadata) do
    context = Map.put(context, :payment_attempt_id, attempt.id)

    with {:ok, _attempt} <- update_attempt(attempt, :mark_verified_success, attrs, context),
         {:ok, line} <- load_single_order_line(order),
         recovery_ctx =
           LatePaymentRecovery.build_ctx(
             attempt.id,
             line.ticket_offer_id,
             order.public_reference,
             line.quantity
           ),
         mark_paid_fn = fn -> mark_late_recovery_paid_inner(order, session, context) end,
         {:ok, _recovered} <- LatePaymentRecovery.recover(recovery_ctx, mark_paid_fn),
         :ok <- finalize_event_processed(event, context) do
      emit_payment_telemetry(:verified, Map.put(metadata, :paid, true))
      OutcomeBroadcast.broadcast(:late_payment_recovered, metadata)
      {:ok, :late_payment_recovered}
    else
      {:error, :manual_review, reason_code} ->
        apply_late_payment_manual_review(
          attempt,
          order,
          session,
          event,
          reason_code,
          context,
          metadata
        )

      {:error, :paid_reconciliation_required, reason_code, _paid_result} ->
        apply_late_payment_paid_reconciliation(event, reason_code, context, metadata)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_late_payment_paid_reconciliation(event, reason_code, context, metadata) do
    with :ok <- finalize_event_processed(event, context) do
      emit_payment_telemetry(:verified, Map.put(metadata, :paid, true))

      emit_manual_review_telemetry(
        Map.put(metadata, :inventory_reconciliation, true),
        reason_code
      )

      OutcomeBroadcast.broadcast(
        :late_payment_recovered,
        Map.put(metadata, :reason_code, reason_code)
      )

      {:ok, :late_payment_recovered}
    end
  end

  defp apply_late_payment_manual_review(
         attempt,
         order,
         session,
         event,
         reason_code,
         context,
         metadata
       ) do
    review_attrs = %{
      manual_review_reason: reason_code,
      last_error_code: reason_code,
      last_error_message: "Late payment could not be safely recovered"
    }

    with {:ok, _} <- mark_order_manual_review(order, review_attrs, context, reason_code),
         {:ok, _} <- mark_session_manual_review(session, reason_code, context),
         :ok <- finalize_event_manual_review(event, reason_code, context) do
      emit_manual_review_telemetry(
        Map.put(metadata, :payment_attempt_id, attempt.id),
        reason_code
      )

      OutcomeBroadcast.broadcast(
        :late_payment_manual_review,
        Map.put(metadata, :reason_code, reason_code)
      )

      {:ok, :late_payment_manual_review}
    end
  end

  defp apply_duplicate(attempt, _order, _session, event, attrs, context, metadata) do
    reason = Map.get(attrs, :reason_code, Reasons.payment_duplicate_suspicious())

    duplicate_attrs = %{
      failure_code: reason,
      failure_message: "Duplicate payment on already settled checkout"
    }

    with {:ok, _} <- update_attempt(attempt, :mark_duplicate, duplicate_attrs, context),
         :ok <- maybe_mark_event_processed_or_duplicate(event, context) do
      emit_payment_telemetry(:verified, Map.put(metadata, :idempotent, true))
      OutcomeBroadcast.broadcast(:duplicate_ignored, Map.put(metadata, :reason_code, reason))
      {:ok, :idempotent}
    end
  end

  defp apply_mismatch(attempt, order, session, event, attempt_action, attrs, context, metadata) do
    reason = Map.get(attrs, :reason_code)

    with {:ok, _} <- update_attempt(attempt, attempt_action, attrs, context),
         {:ok, _} <- mark_order_manual_review(order, attrs, context, reason),
         {:ok, _} <- mark_session_manual_review(session, reason, context),
         :ok <- finalize_event_processed(event, context) do
      emit_payment_telemetry(:mismatch, metadata)
      OutcomeBroadcast.broadcast(:mismatch, Map.put(metadata, :reason_code, reason))
      OutcomeBroadcast.broadcast(:manual_review, Map.put(metadata, :reason_code, reason))
      emit_manual_review_telemetry(metadata, reason)
      {:ok, :mismatch}
    end
  end

  defp apply_reference_mismatch(attempt, order, session, event, attrs, context, metadata) do
    reason = Map.get(attrs, :reason_code, Reasons.payment_reference_mismatch())

    with {:ok, _} <-
           update_attempt(
             attempt,
             :mark_manual_review,
             Map.take(attrs, [:failure_code, :failure_message, :manual_review_reason]),
             context,
             reason: reason
           ),
         {:ok, _} <- mark_order_manual_review(order, attrs, context, reason),
         {:ok, _} <- mark_session_manual_review(session, reason, context),
         :ok <- finalize_event_manual_review(event, reason, context) do
      emit_payment_telemetry(:mismatch, metadata)
      OutcomeBroadcast.broadcast(:mismatch, Map.put(metadata, :reason_code, reason))
      emit_manual_review_telemetry(metadata, reason)
      {:ok, :manual_review}
    end
  end

  defp apply_provider_failed(attempt, event, attrs, context, metadata) do
    attrs =
      Map.take(attrs, [:provider_status, :failure_code, :failure_message, :last_verified_at])

    with {:ok, _} <- update_attempt(attempt, :mark_verification_failed, attrs, context),
         :ok <- finalize_event_processed(event, context) do
      emit_payment_telemetry(:failed, metadata)
      {:ok, :failed}
    end
  end

  defp apply_manual_review_all(attempt, order, session, event, attrs, context, metadata) do
    reason = Map.get(attrs, :reason_code, Reasons.payment_state_conflict())

    with {:ok, _} <-
           update_attempt(
             attempt,
             :mark_manual_review,
             %{manual_review_reason: reason},
             context,
             reason: reason
           ),
         {:ok, _} <- mark_order_manual_review(order, attrs, context, reason),
         {:ok, _} <- mark_session_manual_review(session, reason, context),
         :ok <- finalize_event_manual_review(event, reason, context) do
      emit_manual_review_telemetry(metadata, reason)
      {:ok, :manual_review}
    end
  end

  defp mark_order_and_session_paid(order, session, context) do
    with {:ok, order} <-
           order
           |> Changeset.for_update(:mark_paid_verified, %{}, actor: context.actor)
           |> ash_update(context),
         {:ok, session} <-
           session
           |> Changeset.for_update(:mark_paid, %{}, actor: context.actor)
           |> ash_update(context) do
      {:ok, {order, session}}
    end
  end

  defp mark_late_recovery_paid_inner(order, session, context) do
    with {:ok, order} <-
           order
           |> Changeset.for_update(:mark_paid_verified_from_late_recovery, %{},
             actor: context.actor
           )
           |> ash_update(context),
         {:ok, session} <-
           session
           |> Changeset.for_update(:recover_expired_paid_session_to_paid, %{},
             actor: context.actor
           )
           |> ash_update(context) do
      {:ok, {order, session}}
    end
  end

  defp mark_order_manual_review(order, attrs, context, reason) do
    order
    |> Changeset.new()
    |> Changeset.set_argument(:reason, reason)
    |> Changeset.for_update(
      :mark_manual_review,
      %{
        manual_review_reason: reason,
        last_error_code: Map.get(attrs, :failure_code, reason),
        last_error_message: Map.get(attrs, :failure_message)
      },
      actor: context.actor
    )
    |> ash_update(context)
  end

  defp mark_session_manual_review(session, reason, context) do
    session
    |> Changeset.new()
    |> Changeset.set_argument(:reason, reason)
    |> Changeset.for_update(:recover_expired_paid_session_to_manual_review, %{},
      actor: context.actor
    )
    |> ash_update(context)
  end

  defp load_single_order_line(order) do
    lines =
      OrderLine
      |> Query.for_read(:list_for_order, %{sales_order_id: order.id})
      |> Ash.read!(authorize?: false)

    case lines do
      [line] -> {:ok, line}
      [] -> {:error, :manual_review, Reasons.payment_state_conflict()}
      _ -> {:error, :manual_review, Reasons.payment_state_conflict()}
    end
  end

  defp update_attempt(attempt, action, attrs, context, opts \\ []) do
    reason = Keyword.get(opts, :reason)
    attrs = filter_attempt_attrs(action, attrs)

    changeset =
      attempt
      |> Changeset.for_update(action, attrs, actor: context.actor)
      |> then(fn cs ->
        if reason, do: Changeset.set_argument(cs, :reason, reason), else: cs
      end)

    case ash_update(changeset, context) do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> {:error, error}
    end
  end

  defp ash_update(changeset, context) do
    case Ash.update(changeset, authorize?: false, context: context, return_notifications?: true) do
      {:ok, record, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, record}

      {:ok, record} ->
        {:ok, record}

      {:error, error} ->
        {:error, error}
    end
  end

  defp filter_attempt_attrs(action, attrs) do
    allowed =
      case action do
        :mark_verified_success ->
          ~w(provider_status last_verified_at provider_paid_at verified_at raw_verify_response)a

        :mark_verified_amount_mismatch ->
          ~w(provider_status last_verified_at raw_verify_response)a

        :mark_verified_currency_mismatch ->
          ~w(provider_status last_verified_at raw_verify_response)a

        :mark_verification_failed ->
          ~w(provider_status failure_code failure_message last_verified_at)a

        :mark_manual_review ->
          ~w(manual_review_reason failure_code failure_message)a

        :mark_duplicate ->
          ~w(failure_code failure_message)a

        _ ->
          Map.keys(attrs)
      end

    Map.take(attrs, allowed)
  end

  defp finalize_event_processed(nil, _context), do: :ok

  defp finalize_event_processed(%{processing_status: "processed"}, _context), do: :ok

  defp finalize_event_processed(%{processing_status: "duplicate"}, _context), do: :ok

  defp finalize_event_processed(event, context) do
    case event
         |> Changeset.for_update(:mark_processed, %{}, actor: context.actor)
         |> ash_update(context) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp finalize_event_manual_review(nil, _reason, _context), do: :ok

  defp finalize_event_manual_review(%{processing_status: "manual_review"}, _reason, _context),
    do: :ok

  defp finalize_event_manual_review(%{processing_status: "processed"}, _reason, _context), do: :ok

  defp finalize_event_manual_review(%{processing_status: "duplicate"}, _reason, _context), do: :ok

  defp finalize_event_manual_review(event, reason, context) do
    case event
         |> Changeset.for_update(
           :mark_manual_review,
           %{last_processing_error: reason},
           actor: context.actor
         )
         |> ash_update(context) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_mark_event_processed_or_duplicate(nil, _context), do: :ok

  defp maybe_mark_event_processed_or_duplicate(%{processing_status: "processed"}, _context),
    do: :ok

  defp maybe_mark_event_processed_or_duplicate(%{processing_status: "duplicate"}, _context),
    do: :ok

  defp maybe_mark_event_processed_or_duplicate(event, context) do
    case event
         |> Changeset.for_update(:mark_duplicate, %{}, actor: context.actor)
         |> ash_update(context) do
      {:ok, _} -> :ok
      {:error, _} -> finalize_event_processed(event, context)
    end
  end

  defp build_metadata(outcome, attrs, attempt, order, session, event, context) do
    %{
      outcome: outcome,
      payment_attempt_id: attempt.id,
      payment_event_id: event && event.id,
      order_id: order.id,
      checkout_session_id: session.id,
      reason_code: Map.get(attrs, :reason_code),
      correlation_id: context.correlation_id
    }
    |> Correlation.operational_metadata()
    |> Map.new()
  end

  defp emit_payment_telemetry(kind, metadata) do
    event =
      case kind do
        :verified -> [:fastcheck, :sales, :payment, :verified]
        :mismatch -> [:fastcheck, :sales, :payment, :mismatch]
        :failed -> [:fastcheck, :sales, :payment, :failed]
      end

    :telemetry.execute(event, %{count: 1}, metadata)
  end

  defp emit_manual_review_telemetry(metadata, reason_code) do
    :telemetry.execute(
      [:fastcheck, :sales, :manual_review, :opened],
      %{count: 1},
      Map.put(metadata, :reason_code, reason_code)
    )
  end
end
