defmodule FastCheck.Sales.RefundInventory do
  @moduledoc """
  Resolves inventory for a durable full-refund record.

  Held inventory is released with refund-specific idempotency evidence. Consumed
  inventory remains consumed. Missing or unverifiable holds require review.
  """

  alias Ash.Changeset
  alias FastCheck.Repo
  alias FastCheck.Sales.Inventory.ReservationLedger
  alias FastCheck.Sales.{Order, OrderLine, PaymentAttempt, Refund}

  @system_actor %{actor_type: :system, actor_id: "refund_inventory_worker"}

  @spec resolve(pos_integer()) :: {:ok, Refund.t()} | {:error, term()}
  def resolve(refund_id) when is_integer(refund_id) and refund_id > 0 do
    with {:ok, authority} <- load_authority(refund_id) do
      case authority.refund.status do
        "completed" ->
          {:ok, authority.refund}

        "inventory_manual_review" ->
          {:ok, authority.refund}

        "inventory_pending" ->
          resolve_pending(authority)

        _ ->
          {:error, :refund_not_inventory_pending}
      end
    end
  end

  def resolve(_refund_id), do: {:error, :refund_not_found}

  @doc "Marks an exhausted inventory resolution for audited manual review."
  @spec mark_inventory_manual_review(pos_integer(), String.t()) ::
          {:ok, Refund.t()} | {:error, term()}
  def mark_inventory_manual_review(refund_id, reason)
      when is_integer(refund_id) and refund_id > 0 and is_binary(reason) do
    with {:ok, %{order: order}} <- load_authority(refund_id) do
      transition_under_order_lock(refund_id, order.id, fn refund ->
        case refund.status do
          "inventory_pending" ->
            update_refund(refund, :mark_inventory_manual_review, reason)

          "inventory_manual_review" ->
            {:ok, refund, []}

          "completed" ->
            {:ok, refund, []}

          _ ->
            {:error, :refund_not_inventory_pending}
        end
      end)
    end
  end

  def mark_inventory_manual_review(_refund_id, _reason),
    do: {:error, :refund_not_found}

  defp resolve_pending(authority) do
    case validate_authority(authority) do
      :ok ->
        resolve_hold(authority)

      {:error, reason} ->
        mark_inventory_manual_review(authority.refund.id, reason)
    end
  end

  defp resolve_hold(authority) do
    line = hd(authority.order_lines)

    case ReservationLedger.get_hold_detail(line.ticket_offer_id, authority.order.public_reference) do
      {:ok, nil} ->
        mark_inventory_manual_review(authority.refund.id, "inventory_hold_missing")

      {:ok, detail} ->
        cond do
          not exact_hold?(detail, authority, line) ->
            mark_inventory_manual_review(authority.refund.id, "inventory_hold_mismatch")

          expired_or_unverifiable_hold?(detail) ->
            mark_inventory_manual_review(authority.refund.id, "inventory_hold_expired")

          true ->
            resolve_exact_hold(detail, authority, line)
        end

      {:error, reason, _meta} when reason in [:ledger_unavailable, :lock_timeout] ->
        {:error, {:retryable_inventory, reason}}

      {:error, _reason, _meta} ->
        mark_inventory_manual_review(authority.refund.id, "inventory_hold_unverifiable")
    end
  end

  defp resolve_exact_hold(%{status: :consumed}, authority, _line) do
    persist_resolution(authority.refund.id, "retained_consumed")
  end

  defp resolve_exact_hold(%{status: status}, authority, line) when status in [:held, :released] do
    refund_id = authority.refund.id
    release_key = "refund:release:#{refund_id}"

    case ReservationLedger.release(
           line.ticket_offer_id,
           authority.order.public_reference,
           release_key,
           expected_quantity: line.quantity,
           require_unexpired?: true
         ) do
      {:ok, %{status: :released} = result} ->
        if status == :released and not Map.get(result, :idempotent, false) do
          mark_inventory_manual_review(refund_id, "inventory_release_evidence_missing")
        else
          persist_resolution(refund_id, "released_unconsumed")
        end

      {:error, :already_consumed, _meta} ->
        confirm_consumed_after_release_race(authority, line)

      {:error, reason, _meta} when reason in [:ledger_unavailable, :lock_timeout] ->
        {:error, {:retryable_inventory, reason}}

      {:error, _reason, _meta} ->
        mark_inventory_manual_review(refund_id, "inventory_release_ambiguous")

      _other ->
        mark_inventory_manual_review(refund_id, "inventory_release_unverifiable")
    end
  end

  defp resolve_exact_hold(_detail, authority, _line) do
    mark_inventory_manual_review(authority.refund.id, "inventory_hold_unverifiable")
  end

  defp confirm_consumed_after_release_race(authority, line) do
    case ReservationLedger.get_hold_detail(line.ticket_offer_id, authority.order.public_reference) do
      {:ok, %{status: :consumed} = detail} ->
        if exact_hold?(detail, authority, line) do
          persist_resolution(authority.refund.id, "retained_consumed")
        else
          mark_inventory_manual_review(authority.refund.id, "inventory_hold_mismatch")
        end

      {:error, reason, _meta} when reason in [:ledger_unavailable, :lock_timeout] ->
        {:error, {:retryable_inventory, reason}}

      _ ->
        mark_inventory_manual_review(authority.refund.id, "inventory_release_ambiguous")
    end
  end

  defp exact_hold?(detail, authority, line) do
    detail.offer_id == line.ticket_offer_id and
      detail.order_public_reference == authority.order.public_reference and
      detail.quantity == line.quantity
  end

  defp expired_or_unverifiable_hold?(%{status: :held, expires_at: expires_at})
       when is_integer(expires_at),
       do: expires_at <= System.system_time(:millisecond)

  defp expired_or_unverifiable_hold?(%{status: status}) when status in [:consumed, :released],
    do: false

  defp expired_or_unverifiable_hold?(_detail), do: true

  defp validate_authority(%{
         refund: refund,
         order: order,
         payment_attempt: payment_attempt,
         order_lines: [line]
       }) do
    with :ok <- validate_refund_order(order),
         :ok <- validate_refund_links(order, payment_attempt, refund),
         :ok <- validate_refunded_payment(payment_attempt),
         :ok <- validate_payment_attempt_count(order.id),
         :ok <- validate_refund_evidence(refund),
         :ok <- validate_refund_order_line_amounts(order, payment_attempt, refund, line),
         :ok <- validate_refund_order_line_currencies(order, payment_attempt, refund, line) do
      validate_refund_order_line(line)
    end
  end

  defp validate_authority(_authority), do: {:error, "refund_order_line_ambiguous"}

  defp validate_refund_order(%Order{status: "refunded"}), do: :ok
  defp validate_refund_order(_order), do: {:error, "refund_order_state_mismatch"}

  defp validate_refund_links(order, payment_attempt, refund) do
    if refund.sales_order_id == order.id and payment_attempt.sales_order_id == order.id and
         refund.payment_attempt_id == payment_attempt.id do
      :ok
    else
      {:error, "refund_authority_mismatch"}
    end
  end

  defp validate_refunded_payment(%PaymentAttempt{provider: "paystack", status: "refunded"}),
    do: :ok

  defp validate_refunded_payment(_payment_attempt), do: {:error, "refund_payment_state_mismatch"}

  defp validate_payment_attempt_count(order_id) do
    case Repo.query!(
           """
           SELECT count(*)
           FROM sales_payment_attempts
           WHERE sales_order_id = $1
             AND status IN ('verified_success', 'refunded')
           """,
           [order_id]
         ).rows do
      [[1]] -> :ok
      _ -> {:error, "refund_payment_attempt_ambiguous"}
    end
  end

  defp validate_refund_evidence(%Refund{
         provider: "paystack",
         provider_status: "processed",
         provider_refund_reference: reference,
         provider_refunded_at: refunded_at,
         recorded_by: recorded_by,
         reason: reason,
         revocation_completed_at: completed_at
       }) do
    if nonblank?(reference) and not is_nil(refunded_at) and nonblank?(recorded_by) and
         nonblank?(reason) and not is_nil(completed_at) do
      :ok
    else
      {:error, "refund_evidence_incomplete"}
    end
  end

  defp validate_refund_evidence(_refund), do: {:error, "refund_evidence_incomplete"}

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_refund_order_line_amounts(order, payment_attempt, refund, line) do
    if refund.amount_cents == order.total_amount_cents and
         refund.amount_cents == payment_attempt.amount_cents and
         refund.amount_cents == line.total_amount_cents do
      :ok
    else
      {:error, "refund_amount_mismatch"}
    end
  end

  defp validate_refund_order_line_currencies(order, payment_attempt, refund, line) do
    if refund.currency == order.currency and refund.currency == payment_attempt.currency and
         refund.currency == line.currency do
      :ok
    else
      {:error, "refund_currency_mismatch"}
    end
  end

  defp validate_refund_order_line(line) do
    if is_integer(line.ticket_offer_id) and is_integer(line.quantity) and line.quantity > 0 do
      :ok
    else
      {:error, "refund_order_line_invalid"}
    end
  end

  defp persist_resolution(refund_id, resolution) do
    with {:ok, %{order: order}} <- load_authority(refund_id) do
      transition_under_order_lock(refund_id, order.id, fn refund ->
        with {:ok, authority} <- load_authority(refund.id),
             :ok <- validate_authority(authority) do
          case refund.status do
            "inventory_pending" ->
              action =
                case resolution do
                  "released_unconsumed" -> :complete_released_unconsumed
                  "retained_consumed" -> :complete_retained_consumed
                end

              update_refund(refund, action, "refund inventory resolved as #{resolution}")

            "completed" when refund.inventory_resolution_status == resolution ->
              {:ok, refund, []}

            _ ->
              {:error, :refund_state_conflict}
          end
        end
      end)
    end
  end

  defp transition_under_order_lock(refund_id, order_id, transition) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      refund =
        case Ash.get(Refund, refund_id, authorize?: false) do
          {:ok, %Refund{sales_order_id: ^order_id} = current} -> current
          {:ok, _other} -> Repo.rollback(:refund_authority_mismatch)
          {:error, error} -> Repo.rollback(error)
        end

      case transition.(refund) do
        {:ok, updated, notifications} -> {updated, notifications}
        {:ok, updated} -> {updated, []}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {refund, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, refund}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_authority(refund_id) do
    with {:ok, %Refund{} = refund} <- load(Refund, refund_id),
         {:ok, %Order{} = order} <- load(Order, refund.sales_order_id),
         {:ok, %PaymentAttempt{} = payment_attempt} <-
           load(PaymentAttempt, refund.payment_attempt_id),
         {:ok, order_lines} <- read_order_lines(order.id) do
      {:ok,
       %{
         refund: refund,
         order: order,
         payment_attempt: payment_attempt,
         order_lines: order_lines
       }}
    else
      {:ok, nil} -> {:error, :refund_not_found}
      {:error, _} = error -> error
    end
  end

  defp load(resource, id) do
    case Ash.get(resource, id, authorize?: false) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error}
    end
  end

  defp read_order_lines(order_id) do
    OrderLine
    |> Ash.Query.for_read(:list_for_order, %{sales_order_id: order_id})
    |> Ash.read(authorize?: false)
  end

  defp update_refund(refund, action, reason) do
    refund
    |> Changeset.for_update(action, %{reason: reason}, actor: @system_actor)
    |> Ash.update(
      authorize?: false,
      context: %{actor: @system_actor},
      return_notifications?: true
    )
  end
end
