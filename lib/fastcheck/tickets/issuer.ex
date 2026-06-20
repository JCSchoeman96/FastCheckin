defmodule FastCheck.Tickets.Issuer do
  @moduledoc """
  Approved ticket issuance orchestration entrypoint for FastCheck Sales.

  VS-09B implements the Attendee creation bridge only. It creates or reuses
  existing Ecto attendees for verified paid Sales orders, then returns the
  attendee identifiers for VS-09C to link `TicketIssue` audit rows later.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias Ash.Query
  alias FastCheck.Attendees
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Tickets.CodeGenerator

  @source_fastcheck_sales "fastcheck_sales"
  @payment_status_completed "completed"
  @scan_eligibility_active "active"
  @allowed_order_states ["paid_verified", "fulfillment_queued"]
  @paid_checkout_states ["paid"]
  @ticket_code_attempts 5

  @doc """
  Issue tickets for a verified paid Sales order.

  See `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md` for preconditions,
  return shapes, idempotency, and transaction model.
  """
  @spec issue_order(integer(), keyword()) ::
          {:ok,
           %{
             order_id: integer(),
             status: :attendees_ready | :attendees_already_ready,
             attendee_count: non_neg_integer(),
             attendees: [%{id: integer(), source_reference: String.t()}]
           }}
          | {:error,
             {:invalid_order_state, String.t()}
             | {:invalid_payment_state, :missing_verified_success}
             | {:invalid_checkout_state, String.t() | :missing}
             | {:manual_review_required, atom()}
             | atom()
             | term()}
  def issue_order(order_id, opts \\ [])

  def issue_order(order_id, opts) when is_integer(order_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      with {:ok, order} <- load_order(order_id),
           :ok <- require_allowed_order_state(order),
           {:ok, order_lines} <- load_order_lines(order.id),
           {:ok, payment_attempts} <- load_payment_attempts(order.id),
           :ok <- require_verified_payment(payment_attempts, order),
           {:ok, checkout_session} <- load_checkout_session(order.id),
           :ok <- require_paid_checkout(checkout_session),
           {:ok, attendee_results} <- create_or_reuse_attendees(order, order_lines) do
        build_success_result(order.id, attendee_results)
      else
        {:error, _reason} = error -> Repo.rollback(error)
      end
    end)
    |> normalize_transaction_result()
    |> tap(fn
      {:ok, %{order_id: _order_id, attendees: attendees}} ->
        maybe_invalidate_attendee_caches(order_id, attendees, opts)

      _other ->
        :ok
    end)
  end

  def issue_order(_order_id, _opts), do: {:error, :invalid_order_id}

  defp load_order(order_id) do
    case Order
         |> Query.for_read(:get_by_id, %{id: order_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :order_not_found}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_allowed_order_state(%Order{status: status}) when status in @allowed_order_states,
    do: :ok

  defp require_allowed_order_state(%Order{status: status}),
    do: {:error, {:invalid_order_state, status}}

  defp load_order_lines(order_id) do
    case OrderLine
         |> Query.for_read(:list_for_order, %{sales_order_id: order_id})
         |> Ash.read(authorize?: false) do
      {:ok, []} ->
        {:error, :order_lines_not_found}

      {:ok, lines} ->
        lines =
          Enum.sort_by(lines, fn line ->
            {line.line_number || 0, line.id || 0}
          end)

        {:ok, lines}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_payment_attempts(order_id) do
    case PaymentAttempt
         |> Query.filter(expr(sales_order_id == ^order_id))
         |> Ash.read(authorize?: false) do
      {:ok, attempts} -> {:ok, attempts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_verified_payment(payment_attempts, %Order{} = order) do
    verified? =
      Enum.any?(payment_attempts, fn attempt ->
        attempt.status == "verified_success" and
          attempt.amount_cents == order.total_amount_cents and
          attempt.currency == order.currency
      end)

    if verified? do
      :ok
    else
      {:error, {:invalid_payment_state, :missing_verified_success}}
    end
  end

  defp load_checkout_session(order_id) do
    case CheckoutSession
         |> Query.filter(expr(sales_order_id == ^order_id))
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:invalid_checkout_state, :missing}}
      {:ok, session} -> {:ok, session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_paid_checkout(%CheckoutSession{status: status})
       when status in @paid_checkout_states,
       do: :ok

  defp require_paid_checkout(%CheckoutSession{status: status}),
    do: {:error, {:invalid_checkout_state, status}}

  defp create_or_reuse_attendees(%Order{} = order, order_lines) do
    order_lines
    |> Enum.flat_map(&line_units/1)
    |> Enum.reduce_while({:ok, []}, fn {line, sequence}, {:ok, acc} ->
      source_reference = source_reference(order.id, line.id, sequence)

      case create_or_reuse_attendee(order, line, source_reference) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, {:manual_review_required, _reason}} = error -> {:halt, error}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp line_units(%OrderLine{quantity: quantity} = line) do
    for sequence <- 1..quantity, do: {line, sequence}
  end

  defp create_or_reuse_attendee(%Order{} = order, %OrderLine{} = line, source_reference) do
    case get_attendee_by_source_reference(source_reference) do
      nil ->
        insert_attendee(order, line, source_reference)

      %Attendee{} = attendee ->
        if attendee.sales_order_id == order.id and attendee.event_id == order.event_id do
          {:ok, attendee_result(attendee, source_reference, :reused)}
        else
          {:error, {:manual_review_required, :attendee_source_reference_conflict}}
        end
    end
  end

  defp get_attendee_by_source_reference(source_reference) do
    Repo.one(
      from a in Attendee,
        where:
          a.source == ^@source_fastcheck_sales and
            a.source_reference == ^source_reference
    )
  end

  defp insert_attendee(order, line, source_reference, attempts_left \\ @ticket_code_attempts)

  defp insert_attendee(_order, _line, _source_reference, 0),
    do: {:error, {:manual_review_required, :ticket_code_collision}}

  defp insert_attendee(%Order{} = order, %OrderLine{} = line, source_reference, attempts_left) do
    ticket_code = CodeGenerator.generate()

    attrs = %{
      event_id: order.event_id,
      ticket_code: ticket_code,
      first_name: order.buyer_name,
      email: order.buyer_email,
      ticket_type: line.ticket_type || line.offer_name_snapshot,
      allowed_checkins: 1,
      checkins_remaining: 1,
      payment_status: @payment_status_completed,
      scan_eligibility: @scan_eligibility_active,
      source: @source_fastcheck_sales,
      source_reference: source_reference,
      sales_order_id: order.id,
      sales_ticket_issue_id: nil
    }

    %Attendee{}
    |> Attendee.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, attendee} ->
        {:ok, attendee_result(attendee, source_reference, :created)}

      {:error, changeset} ->
        cond do
          constraint_error?(changeset, :ticket_code, :unique) ->
            insert_attendee(order, line, source_reference, attempts_left - 1)

          constraint_error?(changeset, :source_reference, :unique) ->
            case get_attendee_by_source_reference(source_reference) do
              %Attendee{} = attendee
              when attendee.sales_order_id == order.id and attendee.event_id == order.event_id ->
                {:ok, attendee_result(attendee, source_reference, :reused)}

              _other ->
                {:error, {:manual_review_required, :attendee_source_reference_conflict}}
            end

          true ->
            {:error, changeset}
        end
    end
  end

  defp constraint_error?(changeset, field, constraint) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == constraint
      _other -> false
    end)
  end

  defp attendee_result(%Attendee{} = attendee, source_reference, action) do
    %{
      id: attendee.id,
      source_reference: source_reference,
      action: action,
      event_id: attendee.event_id,
      ticket_code: attendee.ticket_code
    }
  end

  defp source_reference(order_id, order_line_id, sequence) do
    "sales:#{order_id}:#{order_line_id}:#{sequence}"
  end

  defp build_success_result(order_id, attendee_results) do
    status =
      if Enum.all?(attendee_results, &(&1.action == :reused)),
        do: :attendees_already_ready,
        else: :attendees_ready

    %{
      order_id: order_id,
      status: status,
      attendee_count: length(attendee_results),
      attendees: Enum.map(attendee_results, &Map.take(&1, [:id, :source_reference]))
    }
  end

  defp normalize_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp maybe_invalidate_attendee_caches(order_id, attendees, _opts) do
    case attendees do
      [%{id: attendee_id} | _] ->
        case Repo.get(Attendee, attendee_id) do
          %Attendee{event_id: event_id} ->
            _ = Attendees.invalidate_attendees_by_event_cache(event_id)
            Enum.each(attendees, &Attendees.delete_attendee_id_cache(&1.id))
            :ok

          nil ->
            :ok
        end

      [] ->
        _ = order_id
        :ok
    end
  end
end
