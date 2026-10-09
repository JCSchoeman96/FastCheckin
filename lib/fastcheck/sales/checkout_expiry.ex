defmodule FastCheck.Sales.CheckoutExpiry do
  @moduledoc """
  Automated checkout session expiry for FastCheck Sales.

  Expires stale unpaid checkout sessions, releases Redis inventory holds through
  `ReservationLedger` only, and uses the same order-level advisory lock as
  payment verification to avoid races with late payment processing.
  """

  import Ecto.Query

  require Ash.Expr
  require Ash.Query

  import Ash.Expr

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Workers.CheckoutExpiryWorker

  @sweeper_statuses ~w(hold_attached payment_link_sent payment_started)
  @expirable_order_statuses ~w(awaiting_payment payment_pending)
  @cancelable_order_statuses ~w(draft awaiting_payment payment_pending)
  @cancelable_session_statuses ~w(created hold_attached payment_link_sent payment_started)
  @hold_anomaly_reason "checkout_expiry_hold_state_mismatch"
  @default_batch_size 200

  @retryable_release_errors ~w(
    ledger_unavailable
    ledger_degraded
    reconciliation_required
    lock_timeout
    unexpected_redis_response
    invalid_quantity
  )a

  @doc """
  Returns bounded checkout session ids eligible for automated expiry sweeps.
  """
  @spec list_expiry_candidates(keyword()) :: [integer()]
  def list_expiry_candidates(opts \\ []) do
    limit = Keyword.get(opts, :limit, batch_size())
    now = Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

    from(cs in "sales_checkout_sessions",
      where: cs.status in ^@sweeper_statuses,
      where: is_nil(cs.expired_at),
      where: not is_nil(cs.expires_at),
      where: cs.expires_at <= ^now,
      order_by: [asc: cs.expires_at, asc: cs.id],
      limit: ^limit,
      select: cs.id
    )
    |> Repo.all()
  end

  @doc """
  Finds expired checkout sessions and enqueues one worker job per session id.
  """
  @spec sweep_and_enqueue(keyword()) ::
          {:ok, %{enqueued: non_neg_integer(), candidate_count: non_neg_integer()}}
  def sweep_and_enqueue(opts \\ []) do
    correlation_id = Keyword.get(opts, :correlation_id)

    :telemetry.execute(
      [:fastcheck, :sales, :checkout_expiry, :sweeper_started],
      %{count: 1},
      %{correlation_id: correlation_id}
    )

    candidate_ids = list_expiry_candidates(opts)

    enqueued =
      Enum.count(candidate_ids, fn session_id ->
        case enqueue_worker(session_id, correlation_id) do
          {:ok, _} -> true
          _ -> false
        end
      end)

    {:ok, %{enqueued: enqueued, candidate_count: length(candidate_ids)}}
  end

  @doc """
  Expires one checkout session and releases its inventory hold when eligible.
  """
  @spec expire_session(integer(), keyword()) ::
          {:ok, atom()}
          | {:error, term()}
  def expire_session(session_id, opts \\ []) when is_integer(session_id) do
    correlation_id = Keyword.get(opts, :correlation_id)

    :telemetry.execute(
      [:fastcheck, :sales, :checkout_expiry, :worker_started],
      %{count: 1},
      %{checkout_session_id: session_id, correlation_id: correlation_id}
    )

    with {:ok, session} <- load_session(session_id),
         {:ok, order} <- load_order(session.sales_order_id) do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [order.id])

        session = reload_session!(session_id)
        order = reload_order!(session.sales_order_id)

        case classify_after_lock(session, order) do
          {:skip, reason} ->
            emit_skip(reason, session, order, correlation_id)
            reason

          {:manual_review, reason} ->
            mark_manual_review!(session, order, reason, correlation_id)
            :manual_review

          {:expire_with_hold, hold_context} ->
            case release_hold(hold_context) do
              :ok ->
                expire_durable!(session, order, hold_context.context)
                emit_expired(:expired, session, order, correlation_id)
                :expired

              {:manual_review, reason} ->
                mark_manual_review!(session, order, reason, correlation_id)
                :manual_review

              {:retry, reason} ->
                Repo.rollback(reason)
            end
        end
      end)
      |> normalize_transaction_result()
    end
  end

  @doc """
  Cancels an unpaid order owned by the supplied conversation.

  The order advisory lock covers the authoritative reload, payment-attempt
  checks, hold release, and durable Order and CheckoutSession transitions.
  A cancelled order never releases inventory through another path.
  """
  @spec cancel_order(integer(), integer(), keyword()) ::
          {:ok, :cancelled | :already_cancelled} | {:error, atom()}
  def cancel_order(order_id, conversation_id, opts \\ [])

  def cancel_order(order_id, conversation_id, opts)
      when is_integer(order_id) and is_integer(conversation_id) and is_list(opts) do
    correlation_id = Keyword.get(opts, :correlation_id)
    reason = Keyword.get(opts, :reason, "customer_requested")

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      with {:ok, order} <- load_order(order_id),
           {:ok, session} <- load_session_for_order(order_id),
           :ok <- verify_conversation_owner(order, conversation_id) do
        cancel_locked(order, session, reason, correlation_id)
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> normalize_transaction_result()
  end

  def cancel_order(_order_id, _conversation_id, _opts),
    do: {:error, :invalid_cancellation_request}

  @doc """
  Returns the best-effort menu hint for whether customer cancellation can be shown.

  This read-only hint is deliberately weaker than `cancel_order/3`: the durable
  cancellation API reloads all records and rechecks these conditions while
  holding the order advisory lock.
  """
  @spec customer_cancellation_available?(map()) :: boolean()
  def customer_cancellation_available?(%{id: order_id, status: status})
      when is_integer(order_id) and status in @cancelable_order_statuses do
    not cancellation_blocker_exists?(order_id)
  end

  def customer_cancellation_available?(_order), do: false

  defp cancel_locked(order, session, reason, correlation_id) do
    case classify_cancellation(order, session) do
      :already_cancelled ->
        :already_cancelled

      {:error, error} ->
        Repo.rollback(error)

      {:ok, hold_context} ->
        case release_hold_for_cancellation(hold_context) do
          :ok ->
            context = cancellation_context(session, order, correlation_id, reason)

            case cancel_durable(order, session, reason, context) do
              :ok ->
                :telemetry.execute(
                  [:fastcheck, :sales, :checkout_expiry, :cancelled],
                  %{count: 1},
                  %{
                    checkout_session_id: session.id,
                    order_id: order.id,
                    correlation_id: correlation_id
                  }
                )

                :cancelled

              {:error, error} ->
                Repo.rollback(error)
            end

          {:error, error} ->
            Repo.rollback(error)
        end
    end
  end

  defp classify_cancellation(order, session) do
    with :ok <- cancellation_state_status(order, session),
         :ok <- cancellation_artifact_status(order.id),
         :ok <- payment_attempt_cancellation_block(order.id),
         :ok <- cancellation_session_status(session) do
      resolve_cancellation_hold_context(session, order)
    end
  end

  defp cancellation_state_status(order, session) do
    cond do
      order.status == "cancelled" and session.status == "cancelled" ->
        :already_cancelled

      order.status == "cancelled" or session.status == "cancelled" ->
        {:error, :cancellation_state_mismatch}

      order.status not in @cancelable_order_statuses ->
        {:error, :order_not_cancellable}

      true ->
        :ok
    end
  end

  defp cancellation_artifact_status(order_id) do
    cond do
      ticket_issue_exists?(order_id) -> {:error, :ticket_issue_exists}
      attendee_exists?(order_id) -> {:error, :attendee_exists}
      true -> :ok
    end
  end

  defp cancellation_session_status(%{status: status}) do
    if status in @cancelable_session_statuses,
      do: :ok,
      else: {:error, :session_not_cancellable}
  end

  defp cancellation_session_status(_session), do: {:error, :session_not_cancellable}

  defp cancellation_blocker_exists?(order_id) do
    payment_attempt_exists?(order_id) or
      ticket_issue_exists?(order_id) or
      attendee_exists?(order_id)
  end

  defp payment_attempt_exists?(order_id) do
    Repo.exists?(
      from(pa in "sales_payment_attempts",
        where: pa.sales_order_id == ^order_id,
        select: 1
      )
    )
  end

  defp payment_attempt_cancellation_block(order_id) do
    cond do
      verified_payment_attempt_exists?(order_id) -> {:error, :payment_verified}
      payment_attempt_exists?(order_id) -> {:error, :payment_attempt_unresolved}
      true -> :ok
    end
  end

  defp verified_payment_attempt_exists?(order_id) do
    Repo.exists?(
      from(pa in "sales_payment_attempts",
        where: pa.sales_order_id == ^order_id,
        where: pa.status == "verified_success",
        select: 1
      )
    )
  end

  defp resolve_cancellation_hold_context(session, order) do
    context = build_context(session, order)

    cond do
      order.status == "draft" and session.status == "created" and clear_no_hold?(session) ->
        {:ok, nil}

      session.status == "created" ->
        {:error, :hold_state_anomaly}

      session.status in @sweeper_statuses ->
        case resolve_hold_context(session, order, context) do
          {:ok, hold_context} -> {:ok, hold_context}
          {:error, :manual_review, _reason} -> {:error, :hold_state_anomaly}
        end

      true ->
        {:error, :session_not_cancellable}
    end
  end

  defp release_hold_for_cancellation(nil), do: :ok

  defp release_hold_for_cancellation(hold_context) do
    case release_hold(hold_context) do
      :ok -> :ok
      {:manual_review, _reason} -> {:error, :hold_state_anomaly}
      {:retry, reason} -> {:error, reason}
    end
  end

  defp cancel_durable(order, session, reason, context) do
    actor = system_actor()

    with {:ok, _order} <-
           order
           |> Changeset.for_update(
             :cancel_order,
             %{manual_review_reason: reason},
             reason: reason,
             actor: actor
           )
           |> Ash.update(authorize?: false, context: context),
         {:ok, _session} <-
           session
           |> Changeset.for_update(:cancel_session, %{}, reason: reason, actor: actor)
           |> Ash.update(authorize?: false, context: context) do
      :ok
    else
      {:error, _error} -> {:error, :cancellation_transition_failed}
    end
  end

  defp verify_conversation_owner(%{sales_conversation_id: conversation_id}, conversation_id),
    do: :ok

  defp verify_conversation_owner(_order, _conversation_id),
    do: {:error, :conversation_mismatch}

  defp load_session_for_order(order_id) do
    case CheckoutSession
         |> Query.filter(expr(sales_order_id == ^order_id))
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :checkout_session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, _} = error -> error
    end
  end

  defp cancellation_context(session, order, correlation_id, reason) do
    build_context(session, order)
    |> Map.put(:correlation_id, correlation_id || "checkout-cancel-#{session.id}")
    |> Map.put(:transition_metadata, %{reason_code: reason, source: "customer_cancel"})
  end

  defp classify_after_lock(session, order) do
    context = build_context(session, order)

    case eligibility_skip(session, order) do
      {:skip, _} = skipped ->
        skipped

      {:manual_review, _} = review ->
        review

      :eligible ->
        case resolve_hold_context(session, order, context) do
          {:ok, hold_context} -> {:expire_with_hold, hold_context}
          {:error, :manual_review, reason} -> {:manual_review, reason}
        end
    end
  end

  defp eligibility_skip(session, order) do
    cond do
      skip_terminal_state?(session, order) ->
        {:skip, :skipped_terminal}

      order.status not in @expirable_order_statuses ->
        {:skip, :skipped_order_status}

      not session_expired?(session) ->
        {:skip, :skipped_not_due}

      session.status not in @sweeper_statuses ->
        {:skip, :skipped_session_status}

      verified_success_payment?(order.id) ->
        {:skip, :skipped_verified}

      ticket_issue_exists?(order.id) ->
        {:skip, :skipped_ticket_issue}

      attendee_exists?(order.id) ->
        {:skip, :skipped_attendee}

      hold_state_anomaly?(session, order) ->
        {:manual_review, @hold_anomaly_reason}

      true ->
        :eligible
    end
  end

  defp skip_terminal_state?(session, order),
    do: terminal_session?(session) or terminal_order?(order)

  defp terminal_session?(session) do
    session.status in ~w(expired released paid manual_review cancelled failed)
  end

  defp terminal_order?(order) do
    order.status in ~w(
      paid_verified paid_unverified manual_review manual_review_held
      fulfillment_queued ticket_issued partially_issued issuance_retry_queued
      no_fulfillment_closed cancelled expired refunded
    )
  end

  defp session_expired?(session) do
    case session.expires_at do
      nil -> false
      expires_at -> DateTime.compare(expires_at, DateTime.utc_now()) != :gt
    end
  end

  defp verified_success_payment?(order_id) do
    Repo.exists?(
      from(pa in "sales_payment_attempts",
        where: pa.sales_order_id == ^order_id,
        where: pa.status == "verified_success",
        select: 1
      )
    )
  end

  defp ticket_issue_exists?(order_id) do
    Repo.exists?(
      from(ti in "sales_ticket_issues", where: ti.sales_order_id == ^order_id, select: 1)
    )
  end

  defp attendee_exists?(order_id) do
    Repo.exists?(from(a in "attendees", where: a.sales_order_id == ^order_id, select: 1))
  end

  defp clear_no_hold?(session) do
    blank?(session.redis_hold_key) and
      (is_nil(session.hold_quantity) or session.hold_quantity == 0)
  end

  defp hold_state_anomaly?(session, order) do
    held_status?(session) and
      (clear_no_hold?(session) or blank?(order.public_reference) or
         invalid_hold_facts?(session, order))
  end

  defp held_status?(session), do: session.status in @sweeper_statuses

  defp invalid_hold_facts?(session, order) do
    blank?(session.redis_hold_key) or is_nil(session.hold_quantity) or session.hold_quantity <= 0 or
      blank?(order.public_reference) or order_lines_invalid?(order, session)
  end

  defp order_lines_invalid?(order, session) do
    case load_order_lines(order.id) do
      {:ok, []} ->
        true

      {:ok, lines} ->
        line_qty = Enum.map(lines, & &1.quantity) |> Enum.sum()
        line_qty != session.hold_quantity

      {:error, _} ->
        true
    end
  end

  defp resolve_hold_context(session, order, context) do
    with {:ok, lines} <- load_order_lines(order.id),
         false <- lines == [],
         false <- blank?(order.public_reference),
         false <- blank?(session.redis_hold_key),
         false <- is_nil(session.hold_quantity) or session.hold_quantity <= 0 do
      line_qty = Enum.map(lines, & &1.quantity) |> Enum.sum()

      if line_qty != session.hold_quantity do
        {:error, :manual_review, @hold_anomaly_reason}
      else
        offer_id = List.first(lines).ticket_offer_id

        {:ok,
         %{
           offer_id: offer_id,
           public_reference: order.public_reference,
           release_key: release_idempotency_key(session.id),
           context: context
         }}
      end
    else
      _ -> {:error, :manual_review, @hold_anomaly_reason}
    end
  end

  defp release_hold(%{offer_id: offer_id, public_reference: public_reference, release_key: key}) do
    case do_release(offer_id, public_reference, key) do
      {:ok, _} ->
        :ok

      {:error, :already_released, _} ->
        :ok

      {:error, :hold_expired, _} ->
        :ok

      {:error, :hold_not_found, _} ->
        {:manual_review, @hold_anomaly_reason}

      {:error, :already_consumed, _} ->
        {:manual_review, @hold_anomaly_reason}

      {:error, reason, _} when reason in @retryable_release_errors ->
        {:retry, reason}

      {:error, reason, _} ->
        {:retry, reason}
    end
  end

  defp do_release(offer_id, public_reference, key) do
    case Application.get_env(:fastcheck, :checkout_expiry_release_fun) do
      fun when is_function(fun, 3) ->
        fun.(offer_id, public_reference, key)

      _ ->
        ReservationLedger.release(offer_id, public_reference, key)
    end
  end

  defp expire_durable!(session, order, context) do
    actor = system_actor()

    session
    |> Changeset.for_update(:expire_session, %{}, actor: actor)
    |> Ash.update!(authorize?: false, context: context)

    order
    |> Changeset.for_update(:expire_order, %{}, actor: actor)
    |> Ash.update!(authorize?: false, context: context)
  end

  defp mark_manual_review!(session, order, reason, correlation_id) do
    actor = system_actor()

    context =
      build_context(session, order)
      |> Map.put(:correlation_id, correlation_id)
      |> Map.put(:transition_metadata, %{reason_code: reason})

    order
    |> Changeset.for_update(
      :mark_manual_review,
      %{manual_review_reason: reason, last_error_code: reason},
      reason: reason,
      actor: actor
    )
    |> Ash.update!(authorize?: false, context: context)

    session
    |> Changeset.for_update(:mark_manual_review, %{}, reason: reason, actor: actor)
    |> Ash.update!(authorize?: false, context: context)

    :telemetry.execute(
      [:fastcheck, :sales, :checkout_expiry, :manual_review],
      %{count: 1},
      %{
        checkout_session_id: session.id,
        order_id: order.id,
        reason_code: reason,
        correlation_id: correlation_id
      }
    )
  end

  defp load_session(session_id) do
    case CheckoutSession
         |> Query.for_read(:get_by_id, %{id: session_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :checkout_session_not_found}
      {:ok, session} -> {:ok, session}
      {:error, _} = error -> error
    end
  end

  defp reload_session!(session_id) do
    CheckoutSession
    |> Query.for_read(:get_by_id, %{id: session_id})
    |> Ash.read_one!(authorize?: false)
  end

  defp load_order(order_id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: order_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, _} = error -> error
    end
  end

  defp reload_order!(order_id) do
    Order
    |> Query.for_read(:get_by_id, %{id: order_id})
    |> Ash.read_one!(authorize?: false)
  end

  defp load_order_lines(order_id) do
    case OrderLine
         |> Query.for_read(:list_for_order, %{sales_order_id: order_id})
         |> Ash.read(authorize?: false) do
      {:ok, lines} -> {:ok, lines}
      {:error, _} = error -> error
    end
  end

  defp enqueue_worker(session_id, correlation_id) do
    args =
      %{"checkout_session_id" => session_id}
      |> maybe_put_correlation(correlation_id)

    CheckoutExpiryWorker.new(args) |> Oban.insert()
  end

  defp maybe_put_correlation(args, nil), do: args

  defp maybe_put_correlation(args, correlation_id),
    do: Map.put(args, "correlation_id", correlation_id)

  defp build_context(session, order) do
    %{
      actor: system_actor(),
      correlation_id: "checkout-expiry-#{session.id}",
      source_channel: order.source_channel,
      transition_metadata: %{
        checkout_session_id: session.id,
        order_id: order.id,
        source_channel: order.source_channel
      }
    }
  end

  defp system_actor do
    %{actor_type: :system, actor_id: "checkout_expiry"}
  end

  defp release_idempotency_key(session_id), do: "checkout_expiry:release:#{session_id}"

  defp batch_size do
    Application.get_env(:fastcheck, :sales_checkout_expiry_sweep_batch_size, @default_batch_size)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  defp emit_skip(reason, session, order, correlation_id) do
    :telemetry.execute(
      [:fastcheck, :sales, :checkout_expiry, :skipped],
      %{count: 1},
      %{
        checkout_session_id: session.id,
        order_id: order.id,
        reason: reason,
        correlation_id: correlation_id
      }
    )
  end

  defp emit_expired(kind, session, order, correlation_id) do
    :telemetry.execute(
      [:fastcheck, :sales, :checkout_expiry, :expired],
      %{count: 1},
      %{
        checkout_session_id: session.id,
        order_id: order.id,
        kind: kind,
        correlation_id: correlation_id
      }
    )

    if kind == :expired do
      :telemetry.execute(
        [:fastcheck, :sales, :checkout_expiry, :released],
        %{count: 1},
        %{
          checkout_session_id: session.id,
          order_id: order.id,
          correlation_id: correlation_id
        }
      )
    end
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}

  defp normalize_transaction_result({:error, reason}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_transaction_result({:error, {:error, reason}}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
