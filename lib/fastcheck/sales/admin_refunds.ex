defmodule FastCheck.Sales.AdminRefunds do
  @moduledoc """
  Dashboard admin orchestration for Paystack refunds and cancellations.

  Records manual Paystack evidence and reuses `AdminRevocations` before
  finalizing financial state. Does not call Paystack or mutate scanner state.
  """

  import Ecto.Query

  alias Ash.Changeset
  alias Ash.Notifier
  alias FastCheck.Observability.{Correlation, Redactor, TelemetryNames}
  alias FastCheck.Repo

  alias FastCheck.Sales.{
    AdminRevocations,
    DashboardAccess,
    ManualReview,
    Order,
    PaymentAttempt,
    Refund
  }

  alias FastCheck.Workers.RefundInventoryWorker
  alias FastCheckWeb.Plugs.BrowserAuth

  @admin_source "admin_sales_dashboard"
  @default_limit 25
  @max_limit 25
  @refund_order_statuses ~w(
    paid_verified fulfillment_queued ticket_issued partially_issued
    manual_review manual_review_held issuance_retry_queued
  )

  @doc "Returns bounded, masked order context for admin refund/revoke operations."
  def get_order_operations_context(actor, order_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)

    with {:ok, actor} <- DashboardAccess.actor_for_identity(actor),
         {:ok, order} <- load_order(actor, order_id),
         {:ok, base} <- ManualReview.get_context(actor, "order", order.id),
         {:ok, refund} <- load_refund_by_order(order.id) do
      ticket_counts = ticket_status_counts(order.id)
      tickets = bounded_ticket_summaries(order.id, limit)

      timeline =
        base
        |> Map.get(:timeline, [])
        |> Enum.take(limit)

      {:ok,
       base
       |> Map.put(:order_total_amount_cents, order.total_amount_cents)
       |> Map.put(:order_currency, order.currency)
       |> Map.put(:timeline, timeline)
       |> Map.put(:ticket_rows, tickets)
       |> Map.put(:delivery_attempt_rows, bounded_delivery_attempt_summaries(order.id, limit))
       |> Map.put(:issued_ticket_count, ticket_counts.issued)
       |> Map.put(:revoked_ticket_count, ticket_counts.revoked)
       |> Map.put(:refund_status, refund && refund.status)
       |> Map.put(
         :refund_inventory_resolution_status,
         refund && refund.inventory_resolution_status
       )
       |> Map.put(:available_actions, available_actions(order, ticket_counts, refund))}
    end
  end

  @doc "Records processed Paystack refund evidence, revokes tickets, and finalizes the Order."
  def mark_order_refunded_manual(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- require_admin_actor(actor),
         :ok <- require_reason(attrs),
         :ok <- maybe_require_admin_password(attrs),
         {:ok, order} <- load_order(actor, order_id),
         :ok <- authorize_event(actor, order.event_id),
         {:ok, evidence} <- parse_provider_evidence(attrs),
         {:ok, authority} <- record_refund_evidence(actor, order, evidence, attrs),
         {:ok, result} <- continue_refund(actor, authority, attrs) do
      emit_refund_marked(actor, order.id)
      {:ok, result}
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, order_id, "mark_order_refunded_manual")
        error

      {:error, _} = error ->
        error
    end
  end

  @doc "Retries a refund inventory resolution after an audited admin review."
  def retry_refund_inventory(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- require_admin_actor(actor),
         :ok <- require_reason(attrs),
         :ok <- maybe_require_admin_password(attrs),
         {:ok, order} <- load_order(actor, order_id),
         :ok <- authorize_event(actor, order.event_id),
         {:ok, _refund} <- load_manual_review_refund(order.id) do
      retry_refund_inventory_under_lock(actor, order, attrs)
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, order_id, "retry_refund_inventory")
        error

      {:error, _} = error ->
        error
    end
  end

  defp retry_refund_inventory_under_lock(actor, order, attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order.id])
      current_order = load_order!(actor, order.id)
      ensure_refunded_order!(current_order)
      authorize_event!(actor, current_order.event_id)
      current_refund = load_manual_review_refund!(order.id)
      reason = String.trim(attrs["reason"])

      {retried, notifications} =
        case update_refund_in_transaction(
               current_refund,
               :retry_refund_inventory,
               %{reason: reason},
               actor,
               attrs
             ) do
          {:ok, updated, notifications} -> {updated, notifications}
          {:error, error} -> Repo.rollback(error)
        end

      insert_refund_inventory_job!(retried.id)
      {retried, current_order, notifications}
    end)
    |> case do
      {:ok, {refund, current_order, notifications}} ->
        Notifier.notify(notifications)
        {:ok, %{refund: refund, order: current_order}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_manual_review_refund(order_id) do
    case load_refund_by_order(order_id) do
      {:ok, %Refund{status: "inventory_manual_review"} = refund} -> {:ok, refund}
      {:ok, nil} -> {:error, :refund_not_found}
      {:ok, %Refund{}} -> {:error, :refund_inventory_not_in_manual_review}
      {:error, _} = error -> error
    end
  end

  defp load_manual_review_refund!(order_id) do
    case load_manual_review_refund(order_id) do
      {:ok, refund} -> refund
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_order!(actor, order_id) do
    case load_order(actor, order_id) do
      {:ok, order} -> order
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_refunded_order!(%Order{status: "refunded"}), do: :ok
  defp ensure_refunded_order!(_order), do: Repo.rollback(:invalid_order_state)

  defp authorize_event!(actor, event_id) do
    case authorize_event(actor, event_id) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "Marks an order manually cancelled after revoking issued tickets when present."
  def mark_order_cancelled_manual(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- require_admin_actor(actor),
         :ok <- require_reason(attrs),
         :ok <- maybe_require_admin_password(attrs),
         {:ok, order} <- load_order(actor, order_id),
         :ok <- authorize_event(actor, order.event_id),
         {:ok, revoke_result} <- revoke_issued_tickets(actor, order, attrs) do
      case incomplete_revocation_failures(revoke_result) do
        [_ | _] = failures ->
          maybe_move_to_manual_review(order_id, actor, attrs, failures)
          {:error, {:revoke_failures, failures}}

        [] ->
          case finalize_order_transition(order.id, actor, attrs, :cancelled) do
            {:ok, updated} ->
              {:ok, %{order: updated, revoke: revoke_result}}

            {:error, {:order_revocation_incomplete, count} = error} ->
              maybe_move_to_manual_review(order_id, actor, attrs, [%{error: error}])
              {:error, {:order_revocation_incomplete, count}}

            {:error, _} = error ->
              error
          end
      end
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, order_id, "mark_order_cancelled_manual")
        error

      {:error, _} = error ->
        error
    end
  end

  defp parse_provider_evidence(attrs) do
    provider_status = Map.get(attrs, "provider_status")
    provider_reference = attrs |> Map.get("provider_refund_reference") |> blank_to_nil()
    refunded_at_raw = attrs |> Map.get("provider_refunded_at") |> blank_to_nil()
    amount_raw = Map.get(attrs, "amount_cents")
    currency = attrs |> Map.get("currency") |> blank_to_nil()

    cond do
      provider_status != "processed" ->
        {:error, :provider_refund_not_processed}

      is_nil(provider_reference) ->
        {:error, :provider_refund_reference_required}

      is_nil(refunded_at_raw) ->
        {:error, :provider_refunded_at_required}

      is_nil(currency) ->
        {:error, :refund_currency_required}

      true ->
        with {:ok, refunded_at} <- parse_provider_datetime(refunded_at_raw),
             {:ok, amount_cents} <- parse_amount_cents(amount_raw) do
          {:ok,
           %{
             provider: "paystack",
             provider_status: "processed",
             provider_refund_reference: String.trim(provider_reference),
             provider_refunded_at: refunded_at,
             amount_cents: amount_cents,
             currency: String.trim(currency)
           }}
        end
    end
  end

  defp record_refund_evidence(actor, order, evidence, attrs) do
    case Repo.transaction(fn -> record_refund_evidence_locked(actor, order, evidence, attrs) end) do
      {:ok, {authority, notifications}} ->
        Notifier.notify(notifications)
        {:ok, authority}

      {:error, reason} ->
        {:error, normalize_refund_error(reason)}
    end
  end

  defp record_refund_evidence_locked(actor, order, evidence, attrs) do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [order.id])
    order = load_order!(actor, order.id)
    authorize_event!(actor, order.event_id)

    case load_refund_by_order(order.id) do
      {:ok, %Refund{} = existing} -> reuse_refund_evidence(order, existing, evidence)
      {:ok, nil} -> create_refund_evidence(actor, order, evidence, attrs)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reuse_refund_evidence(order, refund, evidence) do
    if same_provider_evidence?(refund, evidence) do
      payment_attempt = load_payment_attempt!(refund.payment_attempt_id)
      {%{order: order, payment_attempt: payment_attempt, refund: refund}, []}
    else
      Repo.rollback(:conflicting_refund_evidence)
    end
  end

  defp create_refund_evidence(_actor, %Order{status: "refunded"}, _evidence, _attrs),
    do: Repo.rollback(:legacy_refund_without_provider_evidence)

  defp create_refund_evidence(actor, order, evidence, attrs) do
    payment_attempt = select_verified_payment_attempt!(order)
    validate_provider_evidence_amount!(order, payment_attempt, evidence)
    ensure_refundable_order!(order)
    create_refund_record(actor, order, payment_attempt, evidence, attrs)
  end

  defp select_verified_payment_attempt!(order) do
    case select_verified_payment_attempt(order) do
      {:ok, attempt} -> attempt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_payment_attempt!(payment_attempt_id) do
    case load_payment_attempt(payment_attempt_id) do
      {:ok, attempt} -> attempt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_provider_evidence_amount!(order, payment_attempt, evidence) do
    case validate_provider_evidence_amount(order, payment_attempt, evidence) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_refundable_order!(%Order{status: status}) when status in @refund_order_statuses,
    do: :ok

  defp ensure_refundable_order!(_order), do: Repo.rollback(:invalid_order_state)

  defp create_refund_record(actor, order, payment_attempt, evidence, attrs) do
    actor_context = ash_actor(actor, order.event_id, attrs)

    refund_attrs = %{
      sales_order_id: order.id,
      payment_attempt_id: payment_attempt.id,
      provider_refund_reference: evidence.provider_refund_reference,
      provider_refunded_at: evidence.provider_refunded_at,
      amount_cents: evidence.amount_cents,
      currency: evidence.currency,
      reason: String.trim(attrs["reason"]),
      admin_password: attrs["admin_password"]
    }

    {refund, notifications} =
      Refund
      |> Changeset.for_create(:record_full_refund_evidence, refund_attrs, actor: actor_context)
      |> Ash.create(
        authorize?: false,
        context: %{actor: actor_context},
        return_notifications?: true
      )
      |> case do
        {:ok, created, notifications} -> {created, notifications}
        {:ok, created} -> {created, []}
        {:error, error} -> Repo.rollback(error)
      end

    {%{order: order, payment_attempt: payment_attempt, refund: refund}, notifications}
  end

  defp continue_refund(actor, %{order: order, refund: refund} = authority, attrs) do
    case refund.status do
      "evidence_recorded" ->
        revoke_then_finalize(actor, authority, attrs)

      "revocation_manual_review" ->
        with {:ok, retried} <-
               update_refund(
                 refund,
                 :retry_refund_revocation,
                 %{reason: String.trim(attrs["reason"])},
                 actor,
                 attrs
               ) do
          revoke_then_finalize(actor, %{authority | refund: retried}, attrs)
        end

      "revocation_complete" ->
        finalize_refund_financials(actor, authority, attrs, %{
          revoked: [],
          failures: [],
          remaining_issued_count: 0
        })

      state when state in ["inventory_pending", "inventory_manual_review", "completed"] ->
        if order.status == "refunded" do
          {:ok,
           %{
             order: order,
             refund: refund,
             revoke: %{revoked: [], failures: [], remaining_issued_count: 0}
           }}
        else
          {:error, :refund_state_conflict}
        end

      _ ->
        {:error, :refund_state_conflict}
    end
  end

  defp revoke_then_finalize(actor, authority, attrs) do
    case revoke_issued_tickets(actor, authority.order, attrs) do
      {:ok, result} -> handle_revocation_result(actor, authority, attrs, result)
      {:error, _error} -> handle_revocation_error(actor, authority, attrs)
    end
  end

  defp handle_revocation_result(actor, authority, attrs, result) do
    case incomplete_revocation_failures(result) do
      [] ->
        mark_revocation_complete_and_finalize(actor, authority, attrs, result)

      failures ->
        mark_revocation_manual_review(authority.refund, actor, attrs)
        maybe_move_to_manual_review(authority.order.id, actor, attrs, failures)
        {:error, {:revoke_failures, failures}}
    end
  end

  defp mark_revocation_complete_and_finalize(actor, authority, attrs, result) do
    case update_refund(
           authority.refund,
           :mark_revocation_complete,
           %{reason: String.trim(attrs["reason"])},
           actor,
           attrs
         ) do
      {:ok, completed_refund} ->
        finalize_after_revocation(actor, %{authority | refund: completed_refund}, attrs, result)

      {:error, error} ->
        mark_revocation_manual_review(authority.refund, actor, attrs)
        {:error, normalize_refund_error(error)}
    end
  end

  defp finalize_after_revocation(actor, authority, attrs, result) do
    case finalize_refund_financials(actor, authority, attrs, result) do
      {:error, {:order_revocation_incomplete, count} = error} ->
        mark_revocation_manual_review(authority.refund, actor, attrs)
        maybe_move_to_manual_review(authority.order.id, actor, attrs, [%{error: error}])
        {:error, {:order_revocation_incomplete, count}}

      other ->
        other
    end
  end

  defp handle_revocation_error(actor, authority, attrs) do
    mark_revocation_manual_review(authority.refund, actor, attrs)
    failures = [%{error: :revocation_failed}]
    maybe_move_to_manual_review(authority.order.id, actor, attrs, failures)
    {:error, {:revoke_failures, failures}}
  end

  defp mark_revocation_manual_review(refund, actor, attrs) do
    update_refund(
      refund,
      :mark_revocation_manual_review,
      %{reason: String.trim(attrs["reason"])},
      actor,
      attrs
    )
  end

  defp finalize_refund_financials(actor, authority, attrs, revoke_result) do
    order_id = authority.order.id
    refund_id = authority.refund.id

    case Repo.transaction(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

           order = rollback_unwrap(load_order(actor, order_id))
           refund = rollback_unwrap(load_refund(refund_id))
           payment_attempt = rollback_unwrap(load_payment_attempt(refund.payment_attempt_id))

           case authorize_event(actor, order.event_id) do
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end

           case validate_financial_finalization(order, payment_attempt, refund) do
             :ok -> :ok
             {:error, reason} -> Repo.rollback(reason)
           end

           case remaining_issued_ticket_count(order_id) do
             0 -> :ok
             count -> Repo.rollback({:order_revocation_incomplete, count})
           end

           context = %{actor: ash_actor(actor, order.event_id, attrs)}
           reason = String.trim(attrs["reason"])

           {refund, refund_notifications} =
             refund
             |> Changeset.for_update(:mark_inventory_pending, %{reason: reason},
               actor: context.actor
             )
             |> update_in_transaction!(context)

           {payment_attempt, payment_notifications} =
             payment_attempt
             |> Changeset.for_update(
               :mark_payment_refunded,
               %{refund_id: refund.id},
               actor: context.actor
             )
             |> update_in_transaction!(context)

           {order, order_notifications} =
             order
             |> Changeset.for_update(
               :finalize_refund,
               %{refund_id: refund.id, reason: reason},
               actor: context.actor
             )
             |> update_in_transaction!(context)

           case insert_refund_inventory_job(refund.id) do
             {:ok, _job} -> :ok
             {:error, reason} -> Repo.rollback({:refund_inventory_job_insert_failed, reason})
           end

           result = %{order: order, payment_attempt: payment_attempt, refund: refund}
           {result, refund_notifications ++ payment_notifications ++ order_notifications}
         end) do
      {:ok, {result, notifications}} ->
        Notifier.notify(notifications)
        {:ok, Map.put(result, :revoke, revoke_result)}

      {:error, reason} ->
        {:error, normalize_refund_error(reason)}
    end
  end

  defp update_in_transaction!(changeset, context) do
    case Ash.update(changeset,
           authorize?: false,
           context: context,
           return_notifications?: true
         ) do
      {:ok, record, notifications} -> {record, notifications}
      {:ok, record} -> {record, []}
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp validate_financial_finalization(order, payment_attempt, refund) do
    with :ok <- validate_refund_shape(order, payment_attempt, refund),
         true <- refund.status == "revocation_complete" do
      :ok
    else
      false -> {:error, :refund_revocation_not_complete}
      {:error, _} = error -> error
    end
  end

  defp validate_refund_shape(order, payment_attempt, refund) do
    with :ok <- validate_refund_relationships(order, payment_attempt, refund),
         :ok <- validate_verified_payment_attempt(payment_attempt),
         :ok <- validate_processed_provider_refund(payment_attempt, refund),
         :ok <- validate_refund_record_amount(order, payment_attempt, refund),
         :ok <- validate_refund_currency(order, payment_attempt, refund),
         :ok <- validate_refund_revocation(refund) do
      validate_refundable_order_state(order)
    end
  end

  defp validate_refund_relationships(order, payment_attempt, refund) do
    if refund.sales_order_id == order.id and payment_attempt.sales_order_id == order.id and
         refund.payment_attempt_id == payment_attempt.id do
      :ok
    else
      {:error, :refund_authority_mismatch}
    end
  end

  defp validate_verified_payment_attempt(%PaymentAttempt{status: "verified_success"}), do: :ok

  defp validate_verified_payment_attempt(_payment_attempt),
    do: {:error, :verified_payment_required}

  defp validate_processed_provider_refund(payment_attempt, refund) do
    cond do
      payment_attempt.provider != "paystack" or refund.provider != "paystack" or
          refund.provider_status != "processed" ->
        {:error, :provider_refund_not_processed}

      not nonblank?(refund.provider_refund_reference) or
        is_nil(refund.provider_refunded_at) or not nonblank?(refund.recorded_by) or
          not nonblank?(refund.reason) ->
        {:error, :refund_evidence_incomplete}

      true ->
        :ok
    end
  end

  defp validate_refund_record_amount(order, payment_attempt, refund) do
    if refund.amount_cents == order.total_amount_cents and
         refund.amount_cents == payment_attempt.amount_cents do
      :ok
    else
      {:error, :refund_amount_mismatch}
    end
  end

  defp validate_refund_currency(order, payment_attempt, refund) do
    if refund.currency == order.currency and refund.currency == payment_attempt.currency do
      :ok
    else
      {:error, :refund_currency_mismatch}
    end
  end

  defp validate_refund_revocation(%Refund{revocation_completed_at: nil}),
    do: {:error, :refund_revocation_not_complete}

  defp validate_refund_revocation(_refund), do: :ok

  defp validate_refundable_order_state(%Order{status: status})
       when status in @refund_order_statuses,
       do: :ok

  defp validate_refundable_order_state(_order), do: {:error, :invalid_order_state}

  defp select_verified_payment_attempt(order) do
    attempts =
      Repo.all(
        from p in "sales_payment_attempts",
          where: p.sales_order_id == ^order.id and p.status == "verified_success",
          order_by: [asc: p.id],
          select: %{id: p.id}
      )

    case attempts do
      [] ->
        {:error, :verified_payment_required}

      [_first, _second | _rest] ->
        {:error, :ambiguous_payment_attempt}

      [%{id: id}] ->
        with {:ok, payment_attempt} <- load_payment_attempt(id),
             :ok <-
               validate_provider_evidence_amount(order, payment_attempt, %{
                 amount_cents: order.total_amount_cents,
                 currency: order.currency
               }) do
          {:ok, payment_attempt}
        end
    end
  end

  defp validate_provider_evidence_amount(order, payment_attempt, evidence) do
    cond do
      evidence.amount_cents < order.total_amount_cents ->
        {:error, :partial_refund_not_supported}

      evidence.amount_cents != order.total_amount_cents or
          evidence.amount_cents != payment_attempt.amount_cents ->
        {:error, :refund_amount_mismatch}

      evidence.currency != order.currency or evidence.currency != payment_attempt.currency ->
        {:error, :refund_currency_mismatch}

      payment_attempt.provider != "paystack" ->
        {:error, :refund_provider_mismatch}

      true ->
        :ok
    end
  end

  defp same_provider_evidence?(refund, evidence) do
    refund.provider == evidence.provider and refund.provider_status == evidence.provider_status and
      refund.provider_refund_reference == evidence.provider_refund_reference and
      DateTime.compare(refund.provider_refunded_at, evidence.provider_refunded_at) == :eq and
      refund.amount_cents == evidence.amount_cents and refund.currency == evidence.currency
  end

  defp update_refund(refund, action, args, actor, attrs) do
    actor_context = ash_actor(actor, nil, attrs)

    refund
    |> Changeset.for_update(action, args, actor: actor_context)
    |> Ash.update(authorize?: false, context: %{actor: actor_context})
  end

  defp update_refund_in_transaction(refund, action, args, actor, attrs) do
    actor_context = ash_actor(actor, nil, attrs)

    refund
    |> Changeset.for_update(action, args, actor: actor_context)
    |> Ash.update(
      authorize?: false,
      context: %{actor: actor_context},
      return_notifications?: true
    )
    |> case do
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:ok, updated} -> {:ok, updated, []}
      {:error, error} -> {:error, error}
    end
  end

  defp insert_refund_inventory_job(refund_id) do
    RefundInventoryWorker.new(%{refund_id: refund_id})
    |> Oban.insert()
  rescue
    error in Ecto.ConstraintError -> {:error, error}
  end

  defp insert_refund_inventory_job!(refund_id) do
    case insert_refund_inventory_job(refund_id) do
      {:ok, job} -> job
      {:error, reason} -> Repo.rollback({:refund_inventory_job_insert_failed, reason})
    end
  end

  defp load_refund_by_order(order_id) do
    case Repo.one(
           from refund in "sales_refunds",
             where: refund.sales_order_id == ^order_id,
             select: refund.id
         ) do
      nil -> {:ok, nil}
      refund_id -> load_refund(refund_id)
    end
  end

  defp load_refund(refund_id) do
    case Ash.get(Refund, refund_id, authorize?: false) do
      {:ok, nil} -> {:error, :refund_not_found}
      {:ok, refund} -> {:ok, refund}
      {:error, error} -> {:error, error}
    end
  end

  defp load_payment_attempt(payment_attempt_id) do
    case Ash.get(PaymentAttempt, payment_attempt_id, authorize?: false) do
      {:ok, nil} -> {:error, :payment_attempt_not_found}
      {:ok, payment_attempt} -> {:ok, payment_attempt}
      {:error, error} -> {:error, error}
    end
  end

  defp rollback_unwrap({:ok, value}), do: value
  defp rollback_unwrap({:error, reason}), do: Repo.rollback(reason)

  defp normalize_refund_error(%Ash.Error.Invalid{} = error),
    do: {:refund_authority_invalid, error}

  defp normalize_refund_error({:refund_inventory_job_insert_failed, _} = error), do: error
  defp normalize_refund_error(error), do: error

  defp parse_provider_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        case DateTime.shift_zone(datetime, "Etc/UTC") do
          {:ok, utc_datetime} -> {:ok, DateTime.truncate(utc_datetime, :second)}
          {:error, _} -> {:error, :provider_refunded_at_required}
        end

      _ ->
        {:error, :provider_refunded_at_required}
    end
  end

  defp parse_provider_datetime(_), do: {:error, :provider_refunded_at_required}

  defp parse_amount_cents(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_amount_cents(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {amount, ""} when amount > 0 -> {:ok, amount}
      _ -> {:error, :refund_amount_invalid}
    end
  end

  defp parse_amount_cents(_), do: {:error, :refund_amount_invalid}

  defp revoke_issued_tickets(actor, order, attrs) do
    counts = ticket_status_counts(order.id)

    if counts.issued == 0 do
      {:ok, %{revoked: [], failures: [], remaining_issued_count: 0}}
    else
      revoke_attrs =
        attrs
        |> Map.put("confirmed_bulk", "true")
        |> Map.put("admin_password", Map.get(attrs, "admin_password"))

      case AdminRevocations.revoke_order_tickets(actor, order.id, revoke_attrs) do
        {:error, {:revoke_failures, failures}} ->
          {:ok,
           %{
             revoked: [],
             failures: failures,
             remaining_issued_count: remaining_issued_ticket_count(order.id)
           }}

        other ->
          other
      end
    end
  end

  defp transition_cancelled(order, actor, attrs) do
    if order.status == "cancelled" do
      {:ok, order}
    else
      order
      |> Changeset.for_update(
        :mark_cancelled_manual,
        %{reason: Map.get(attrs, "reason")},
        actor: ash_actor(actor, order.event_id, attrs)
      )
      |> Ash.update(authorize?: false)
    end
  end

  defp finalize_order_transition(order_id, actor, attrs, :cancelled) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      order =
        case load_order(actor, order_id) do
          {:ok, order} -> order
          {:error, reason} -> Repo.rollback(reason)
        end

      with :ok <- authorize_event(actor, order.event_id),
           0 <- remaining_issued_ticket_count(order_id) do
        case transition_cancelled(order, actor, attrs) do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} ->
          Repo.rollback(reason)

        remaining_issued_count when is_integer(remaining_issued_count) ->
          Repo.rollback({:order_revocation_incomplete, remaining_issued_count})
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp incomplete_revocation_failures(result) do
    failures = Map.get(result, :failures, Map.get(result, "failures", []))
    remaining_issued_count = Map.get(result, :remaining_issued_count)

    cond do
      failures != [] ->
        failures

      remaining_issued_count == 0 ->
        []

      true ->
        [%{error: :order_revocation_incomplete}]
    end
  end

  defp remaining_issued_ticket_count(order_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id and t.status == "issued",
        select: count(t.id)
    )
  end

  defp maybe_move_to_manual_review(order_id, actor, attrs, failures) do
    reason =
      "Revoke failures during admin refund: #{length(failures)} ticket(s) could not be revoked"

    _ =
      case load_order(actor, order_id) do
        {:ok, order} ->
          order
          |> Changeset.for_update(
            :mark_manual_review,
            %{reason: Map.get(attrs, "reason") || reason},
            actor: ash_actor(actor, order.event_id, attrs)
          )
          |> Ash.update(authorize?: false)

        _ ->
          :ok
      end

    :ok
  end

  defp ticket_status_counts(order_id) do
    rows =
      Repo.all(
        from t in "sales_ticket_issues",
          where: t.sales_order_id == ^order_id and t.status in ["issued", "revoked"],
          group_by: t.status,
          select: {t.status, count(t.id)}
      )

    counts = Map.new(rows)

    %{
      issued: Map.get(counts, "issued", 0),
      revoked: Map.get(counts, "revoked", 0)
    }
  end

  defp bounded_ticket_summaries(order_id, limit) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id,
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: ^limit,
        select: %{
          ticket_issue_id: t.id,
          status: t.status,
          scanner_status: t.scanner_status,
          ticket_code_suffix: fragment("right(?, 4)", t.ticket_code)
        }
    )
    |> Enum.map(fn row ->
      Map.put(row, :ticket_code_suffix, "***#{row.ticket_code_suffix}")
    end)
  end

  defp bounded_delivery_attempt_summaries(order_id, limit) do
    Repo.all(
      from d in "sales_delivery_attempts",
        where: d.sales_order_id == ^order_id,
        order_by: [desc: d.inserted_at, desc: d.id],
        limit: ^limit,
        select: %{
          delivery_attempt_id: d.id,
          ticket_issue_id: d.ticket_issue_id,
          channel: d.channel,
          provider: d.provider,
          status: d.status,
          template_name: d.template_name,
          within_whatsapp_window: d.within_whatsapp_window,
          provider_error_code: d.provider_error_code,
          failure_reason: d.failure_reason,
          fallback_channel: d.fallback_channel,
          sent_at: d.sent_at,
          inserted_at: d.inserted_at
        }
    )
  end

  defp available_actions(order, counts, refund) do
    %{
      can_revoke_ticket: counts.issued > 0,
      can_revoke_order_tickets: counts.issued > 0,
      can_mark_refunded: order.status in @refund_order_statuses,
      can_mark_cancelled: order.status not in ["cancelled", "refunded"],
      can_retry_refund_inventory:
        order.status == "refunded" and match?(%Refund{status: "inventory_manual_review"}, refund),
      can_hold_investigation: order.status in ["manual_review", "manual_review_held"],
      can_close_no_refund: order.status in ["manual_review", "manual_review_held"]
    }
  end

  defp require_admin_actor(actor) do
    case DashboardAccess.actor_for_identity(actor) do
      {:ok, %{actor_type: :admin}} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize_event(actor, event_id) do
    if DashboardAccess.event_granted?(actor, event_id), do: :ok, else: {:error, :forbidden}
  end

  defp require_reason(attrs) do
    reason = Map.get(attrs, "reason") |> blank_to_nil()

    if is_binary(reason), do: :ok, else: {:error, :reason_required}
  end

  defp maybe_require_admin_password(attrs) do
    if BrowserAuth.valid_admin_password?(Map.get(attrs, "admin_password")),
      do: :ok,
      else: {:error, :invalid_admin_password}
  end

  defp ash_actor(actor, _event_id, attrs) do
    {:ok, verified_actor} = DashboardAccess.actor_for_identity(actor)

    %{
      actor_type: verified_actor.actor_type,
      actor_id: actor_id(actor),
      allowed_event_ids: verified_actor.allowed_event_ids,
      correlation_id: Map.get(attrs, "correlation_id"),
      idempotency_key: Map.get(attrs, "idempotency_key")
    }
  end

  defp load_order(actor, order_id) do
    with {:ok, id} <- parse_integer(order_id) do
      event_ids = DashboardAccess.allowed_event_ids(actor)

      case Repo.one(from o in Order, where: o.id == ^id and o.event_id in ^event_ids) do
        nil -> {:error, :not_found}
        order -> {:ok, order}
      end
    end
  end

  defp actor_type(actor) do
    case DashboardAccess.actor_for_identity(actor) do
      {:ok, verified_actor} -> verified_actor.actor_type
      _ -> :unknown
    end
  end

  defp actor_id(actor) do
    case DashboardAccess.actor_for_identity(actor) do
      {:ok, verified_actor} -> verified_actor.id
      _ -> "unknown"
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_id}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: value

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp clamp(value, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp emit_refund_marked(actor, order_id) do
    :telemetry.execute(
      TelemetryNames.admin_refund_marked(),
      %{},
      Correlation.operational_metadata(%{
        actor_type: actor_type(actor),
        actor_id: actor_id(actor),
        order_id: order_id,
        source: @admin_source
      })
      |> Redactor.safe_metadata()
    )
  end

  defp emit_denied(actor, order_id, action) do
    :telemetry.execute(
      TelemetryNames.admin_action_denied(),
      %{},
      Correlation.operational_metadata(%{
        actor_type: actor_type(actor),
        actor_id: actor_id(actor),
        order_id: order_id,
        action: action,
        source: @admin_source
      })
      |> Redactor.safe_metadata()
    )
  end
end
