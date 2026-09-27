defmodule FastCheck.Sales.PaidOrderFulfillment do
  @moduledoc """
  Consumes a verified order's inventory hold and atomically queues ticket issuance.

  Redis consumption runs before the Postgres transition. Retries accept only the
  exact consumed hold for the same offer, public order reference, and quantity.
  The order transition and IssueTicketsWorker insertion share one Postgres
  transaction protected by the order advisory lock.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Correlation
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Workers.IssueTicketsWorker

  @already_fulfilled_states ~w(fulfillment_queued partially_issued issuance_retry_queued ticket_issued)
  @retryable_inventory_errors [:ledger_unavailable, :lock_timeout]
  @reconciliation_inventory_errors [:ledger_degraded, :reconciliation_required]

  @spec fulfill(integer(), keyword()) :: {:ok, atom()} | {:error, atom()}
  def fulfill(payment_attempt_id, opts \\ [])

  def fulfill(payment_attempt_id, opts)
      when is_integer(payment_attempt_id) and payment_attempt_id > 0 do
    context = build_context(payment_attempt_id, opts)

    with {:ok, authority} <- load_authority(payment_attempt_id),
         :ok <- require_verified_payment(authority.attempt) do
      fulfill_authorized(authority, context, opts)
    end
  end

  def fulfill(_payment_attempt_id, _opts), do: {:error, :invalid_payment_attempt_id}

  @doc false
  def validate_recovery_authority(payment_attempt_id)
      when is_integer(payment_attempt_id) and payment_attempt_id > 0 do
    with {:ok, authority} <- load_authority(payment_attempt_id),
         :ok <- require_verified_payment(authority.attempt),
         {:ok, _line} <- validate_fulfillment_authority(authority) do
      :ok
    else
      _ -> {:error, :unsafe_fulfillment_authority}
    end
  rescue
    _error -> {:error, :unsafe_fulfillment_authority}
  end

  def validate_recovery_authority(_payment_attempt_id),
    do: {:error, :unsafe_fulfillment_authority}

  defp fulfill_authorized(%{order: %{status: status}}, _context, _opts)
       when status in @already_fulfilled_states,
       do: {:ok, :already_fulfilled}

  defp fulfill_authorized(%{order: %{status: "manual_review"}}, _context, _opts),
    do: {:ok, :manual_review}

  defp fulfill_authorized(%{order: %{status: "paid_verified"}} = authority, context, opts) do
    case validate_fulfillment_authority(authority) do
      {:ok, line} ->
        consume_inventory(authority, line, context, opts)

      {:manual_review, reason_code} ->
        open_manual_review(authority, nil, reason_code, context)
    end
  end

  defp fulfill_authorized(%{order: %{status: status}}, _context, _opts),
    do: {:error, if(status == "paid_verified", do: :retryable, else: :invalid_order_state)}

  defp consume_inventory(authority, line, context, opts) do
    attempt = authority.attempt
    order = authority.order
    consume_key = consume_key(attempt.id)

    case ReservationLedger.consume(
           line.ticket_offer_id,
           order.public_reference,
           line.quantity,
           consume_key
         ) do
      {:ok, _snapshot} ->
        finish_after_consume(authority, line, context, opts)

      {:error, :already_consumed, _metadata} ->
        finish_after_consume(authority, line, context, opts)

      {:error, reason, _metadata} when reason in @retryable_inventory_errors ->
        retry_or_review(authority, reason, context, opts)

      {:error, reason, _metadata} ->
        handle_unsafe_inventory_result(authority, line, reason, context)
    end
  end

  defp finish_after_consume(authority, line, context, opts) do
    case exact_consumed_hold?(line, authority.order) do
      :ok ->
        case transition_and_enqueue(authority, context) do
          {:ok, result} ->
            {:ok, result}

          {:review, reason_code} ->
            open_manual_review(authority, line.ticket_offer_id, reason_code, context)

          {:error, :retryable} ->
            retry_or_review(authority, :database_transition_failed, context, opts)
        end

      {:retryable, _reason} ->
        retry_or_review(authority, :ledger_unavailable, context, opts)

      {:manual_review, reason_code} ->
        handle_unsafe_inventory_result(authority, line, reason_code, context)
    end
  end

  defp exact_consumed_hold?(line, order) do
    case ReservationLedger.get_hold_detail(line.ticket_offer_id, order.public_reference) do
      {:ok,
       %{
         offer_id: offer_id,
         order_public_reference: reference,
         quantity: quantity,
         status: :consumed
       }}
      when offer_id == line.ticket_offer_id and reference == order.public_reference and
             quantity == line.quantity ->
        :ok

      {:ok, _detail} ->
        {:manual_review, "paid_order_fulfillment_hold_mismatch"}

      {:error, :ledger_unavailable, _metadata} ->
        {:retryable, :ledger_unavailable}
    end
  end

  defp handle_unsafe_inventory_result(authority, line, reason, context) do
    reason_code = inventory_reason_code(reason)

    _ =
      ReservationLedger.mark_offer_health(
        line.ticket_offer_id,
        :reconciliation_required,
        reason_code
      )

    open_manual_review(authority, line.ticket_offer_id, reason_code, context)
  end

  defp retry_or_review(authority, _failure, context, opts) do
    if final_attempt?(opts) do
      open_manual_review(
        authority,
        nil,
        "paid_order_fulfillment_retry_exhausted",
        context
      )
    else
      {:error, :retryable}
    end
  end

  defp transition_and_enqueue(authority, context) do
    order_id = authority.order.id

    try do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])
        transition_fresh_authority(authority.attempt.id, context)
      end)
      |> normalize_transition_result()
    rescue
      _error -> {:error, :retryable}
    catch
      :exit, _reason -> {:error, :retryable}
    end
  end

  defp transition_fresh_authority(payment_attempt_id, context) do
    case load_authority(payment_attempt_id) do
      {:ok, authority} ->
        case require_verified_payment(authority.attempt) do
          :ok ->
            transition_authority_state(authority, context)

          {:error, _reason} ->
            Repo.rollback({:review_required, "paid_order_fulfillment_payment_not_verified"})
        end

      {:error, _reason} ->
        Repo.rollback(:retryable)
    end
  end

  defp transition_authority_state(%{order: %{status: status} = order}, _context)
       when status in @already_fulfilled_states,
       do: {:already_fulfilled, order}

  defp transition_authority_state(%{order: %{status: "manual_review"}}, _context),
    do: Repo.rollback({:review_required, "paid_order_fulfillment_state_changed_after_consume"})

  defp transition_authority_state(
         %{order: %{status: "paid_verified"} = order} = authority,
         context
       ) do
    case require_verified_payment(authority.attempt) do
      :ok ->
        case validate_fulfillment_authority(authority) do
          {:ok, _line} -> queue_order_and_insert_issuer(order, context)
          {:manual_review, reason_code} -> Repo.rollback({:review_required, reason_code})
        end

      {:error, _reason} ->
        Repo.rollback({:review_required, "paid_order_fulfillment_payment_not_verified"})
    end
  end

  defp transition_authority_state(_authority, _context),
    do: Repo.rollback({:review_required, "paid_order_fulfillment_state_changed_after_consume"})

  defp normalize_transition_result(result) do
    case result do
      {:ok, {:queued, _order}} -> {:ok, :fulfillment_queued}
      {:ok, {:already_fulfilled, _order}} -> {:ok, :already_fulfilled}
      {:ok, {:manual_review, _order}} -> {:ok, :manual_review}
      {:error, {:review_required, reason_code}} -> {:review, reason_code}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp queue_order_and_insert_issuer(order, context) do
    case order
         |> Changeset.for_update(:queue_fulfillment, %{}, actor: context.actor)
         |> Ash.update(authorize?: true, context: context) do
      {:ok, queued_order} ->
        job =
          IssueTicketsWorker.new(%{
            "sales_order_id" => queued_order.id,
            "idempotency_key" => issue_idempotency_key(queued_order.id),
            "correlation_id" => context.correlation_id
          })

        case Oban.insert(job) do
          {:ok, _job} -> {:queued, queued_order}
          {:error, _reason} -> Repo.rollback(:retryable)
        end

      {:error, _reason} ->
        Repo.rollback(:retryable)
    end
  end

  defp open_manual_review(authority, offer_id, reason_code, context) do
    case authority.order.status do
      "paid_verified" ->
        with :ok <- maybe_require_reconciliation(offer_id, reason_code),
             {:ok, result} <-
               transition_to_manual_review(authority.order.id, reason_code, context) do
          if result == :opened do
            :telemetry.execute(
              [:fastcheck, :sales, :manual_review, :opened],
              %{count: 1},
              %{
                order_id: authority.order.id,
                payment_attempt_id: authority.attempt.id,
                offer_id: offer_id,
                correlation_id: context.correlation_id,
                reason_code: reason_code
              }
            )
          end

          {:ok, :manual_review}
        else
          {:error, _reason} -> {:error, :retryable}
        end

      "manual_review" ->
        {:ok, :manual_review}

      status when status in @already_fulfilled_states ->
        {:ok, :already_fulfilled}

      _status ->
        {:ok, :manual_review}
    end
  end

  defp maybe_require_reconciliation(nil, _reason_code), do: :ok

  defp maybe_require_reconciliation(offer_id, reason_code) do
    case ReservationLedger.mark_offer_health(offer_id, :reconciliation_required, reason_code) do
      :ok -> :ok
      {:error, :ledger_unavailable, _metadata} -> :ok
      {:error, _reason, _metadata} -> :ok
    end
  end

  defp transition_to_manual_review(order_id, reason_code, context) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      case load_order(order_id) do
        {:ok, %{status: "paid_verified"} = order} ->
          attrs = %{
            manual_review_reason: reason_code,
            last_error_code: reason_code,
            last_error_message: "Paid order fulfillment requires manual review."
          }

          case order
               |> Changeset.for_update(:mark_manual_review, attrs, actor: context.actor)
               |> Changeset.set_argument(:reason, reason_code)
               |> Ash.update(authorize?: true, context: context) do
            {:ok, _review_order} -> :opened
            {:error, _reason} -> Repo.rollback(:retryable)
          end

        {:ok, %{status: "manual_review"}} ->
          :already_reviewed

        {:ok, %{status: status}} when status in @already_fulfilled_states ->
          :already_fulfilled

        {:ok, _other} ->
          :no_longer_eligible

        {:error, _reason} ->
          Repo.rollback(:retryable)
      end
    end)
    |> case do
      {:ok, :opened} -> {:ok, :opened}
      {:ok, _other} -> {:ok, :already_reviewed}
      {:error, _reason} -> {:error, :retryable}
    end
  rescue
    _error -> {:error, :retryable}
  end

  defp validate_fulfillment_authority(%{
         attempt: attempt,
         order: order,
         sessions: sessions,
         lines: lines
       }) do
    cond do
      attempt.amount_cents != order.total_amount_cents or attempt.currency != order.currency ->
        {:manual_review, "paid_order_fulfillment_payment_mismatch"}

      not match?([%CheckoutSession{status: "paid"}], sessions) ->
        {:manual_review, "paid_order_fulfillment_checkout_not_paid"}

      match?(
        [%OrderLine{ticket_offer_id: offer_id, quantity: quantity}]
        when is_integer(offer_id) and offer_id > 0 and is_integer(quantity) and quantity > 0,
        lines
      ) ->
        [line] = lines
        {:ok, line}

      true ->
        {:manual_review, "paid_order_fulfillment_order_lines_invalid"}
    end
  end

  defp require_verified_payment(%PaymentAttempt{status: "verified_success"}), do: :ok
  defp require_verified_payment(_attempt), do: {:error, :payment_not_verified}

  defp load_authority(payment_attempt_id) do
    with {:ok, attempt} <- load_attempt(payment_attempt_id),
         {:ok, order} <- load_order(attempt.sales_order_id),
         {:ok, sessions} <- load_sessions(order.id),
         {:ok, lines} <- load_order_lines(order.id) do
      {:ok, %{attempt: attempt, order: order, sessions: sessions, lines: lines}}
    end
  end

  defp load_attempt(id) do
    case PaymentAttempt
         |> Query.for_read(:get_by_id, %{id: id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :payment_attempt_not_found}
      {:ok, attempt} -> {:ok, attempt}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp load_order(id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp load_sessions(order_id) do
    case CheckoutSession
         |> Query.filter(expr(sales_order_id == ^order_id))
         |> Ash.read(authorize?: false) do
      {:ok, sessions} -> {:ok, sessions}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp load_order_lines(order_id) do
    case OrderLine
         |> Query.for_read(:list_for_order, %{sales_order_id: order_id})
         |> Ash.read(authorize?: false) do
      {:ok, lines} -> {:ok, lines}
      {:error, _reason} -> {:error, :retryable}
    end
  end

  defp inventory_reason_code(:hold_not_found), do: "paid_order_fulfillment_hold_missing"
  defp inventory_reason_code(:hold_expired), do: "paid_order_fulfillment_hold_expired"
  defp inventory_reason_code(:already_released), do: "paid_order_fulfillment_hold_released"
  defp inventory_reason_code(:invalid_quantity), do: "paid_order_fulfillment_quantity_mismatch"

  defp inventory_reason_code(reason) when reason in @reconciliation_inventory_errors,
    do: "paid_order_fulfillment_inventory_reconciliation_required"

  defp inventory_reason_code(_reason), do: "paid_order_fulfillment_hold_mismatch"

  defp final_attempt?(opts) do
    attempt = Keyword.get(opts, :attempt, 0)
    max_attempts = Keyword.get(opts, :max_attempts, 0)
    is_integer(attempt) and is_integer(max_attempts) and attempt > 0 and attempt >= max_attempts
  end

  defp build_context(payment_attempt_id, opts) do
    correlation_id =
      Correlation.ensure_correlation_id(%{correlation_id: Keyword.get(opts, :correlation_id)})

    %{
      actor: %{actor_type: :system, actor_id: "paid_order_fulfillment"},
      correlation_id: correlation_id,
      idempotency_key: "paid-order-fulfillment:issue:#{payment_attempt_id}",
      transition_metadata: %{payment_attempt_id: payment_attempt_id}
    }
  end

  defp consume_key(payment_attempt_id),
    do: "paid_order_fulfillment:consume:#{payment_attempt_id}"

  defp issue_idempotency_key(order_id),
    do: "paid-order-fulfillment:issue:#{order_id}"
end
