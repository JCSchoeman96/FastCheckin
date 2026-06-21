defmodule FastCheck.Tickets.Issuer do
  @moduledoc """
  Approved ticket issuance orchestration entrypoint for FastCheck Sales.

  VS-09C links the VS-09B attendee bridge results to durable TicketIssue audit
  rows and finalizes fully issued orders.
  """

  require Ash.Expr
  require Ash.Query

  import Ash.Expr
  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.MobileSyncVersionAggregator
  alias FastCheck.Repo
  alias FastCheck.Sales.CheckoutSession
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.OrderLine
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.CodeGenerator
  alias FastCheck.Tickets.DeliveryToken
  alias FastCheck.Tickets.QrPayload

  @source_fastcheck_sales "fastcheck_sales"
  @payment_status_completed "completed"
  @scan_eligibility_active "active"
  @allowed_order_states [
    "paid_verified",
    "fulfillment_queued",
    "partially_issued",
    "issuance_retry_queued",
    "ticket_issued"
  ]
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
             status: :ticket_issued | :already_issued,
             attendee_count: non_neg_integer(),
             ticket_issue_count: non_neg_integer(),
             ticket_issues: [
               %{id: integer(), attendee_id: integer(), source_reference: String.t()}
             ]
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
    context = issuer_context(opts)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [order_id])

      with {:ok, order} <- load_order(order_id),
           :ok <- require_allowed_order_state(order),
           {:ok, order_lines} <- load_order_lines(order.id),
           {:ok, payment_attempts} <- load_payment_attempts(order.id),
           :ok <- require_verified_payment(payment_attempts, order),
           {:ok, checkout_session} <- load_checkout_session(order.id),
           :ok <- require_paid_checkout(checkout_session),
           {:ok, attendee_results} <- create_or_reuse_attendees(order, order_lines, context),
           {:ok, ticket_issue_result} <-
             create_or_reuse_ticket_issues(order, order_lines, attendee_results, context),
           :ok <-
             maybe_bump_mobile_sync_version(order, attendee_results, ticket_issue_result, opts) do
        ticket_issue_result
      else
        {:manual_review, {:error, _reason} = error} -> error
        {:error, _reason} = error -> Repo.rollback(error)
      end
    end)
    |> normalize_transaction_result()
    |> tap(fn
      {:ok, %{status: :ticket_issued, order_id: _order_id, ticket_issues: ticket_issues}} ->
        maybe_invalidate_mobile_sync_caches(order_id, ticket_issues, opts)

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

  defp create_or_reuse_attendees(%Order{} = order, order_lines, context) do
    units = expected_units(order.id, order_lines)

    with :ok <- require_attendee_source_reference_ownership(order, units, context) do
      units
      |> Enum.reduce_while({:ok, []}, fn unit, {:ok, acc} ->
        case create_or_reuse_attendee(order, unit.line, unit.source_reference, context) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          {:manual_review, {:error, _reason} = error} -> {:halt, {:manual_review, error}}
          {:error, {:manual_review_required, _reason}} = error -> {:halt, error}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, Enum.reverse(results)}
        error -> error
      end
    end
  end

  defp create_or_reuse_ticket_issues(%Order{} = order, order_lines, attendee_results, context) do
    expected_units = expected_units(order.id, order_lines)
    attendees_by_source_reference = Map.new(attendee_results, &{&1.source_reference, &1})

    with {:ok, existing_issues} <- load_ticket_issues(order.id),
         {:ok, linked_issues} <-
           link_expected_units(
             order,
             expected_units,
             attendees_by_source_reference,
             existing_issues,
             context
           ),
         :ok <- ensure_all_units_linked(expected_units, linked_issues),
         {:ok, updated_order} <- mark_order_ticket_issued(order, context) do
      {:ok,
       build_ticket_issue_result(
         order,
         updated_order,
         attendee_results,
         linked_issues,
         complete_existing_issue_set?(expected_units, existing_issues)
       )}
    end
  end

  defp expected_units(order_id, order_lines) do
    Enum.flat_map(order_lines, fn line ->
      for sequence <- 1..line.quantity do
        %{
          line: line,
          sequence: sequence,
          source_reference: source_reference(order_id, line.id, sequence)
        }
      end
    end)
  end

  defp require_attendee_source_reference_ownership(%Order{} = order, units, context) do
    source_references = Enum.map(units, & &1.source_reference)

    conflicting_attendee =
      Repo.one(
        from a in Attendee,
          where:
            a.source == ^@source_fastcheck_sales and
              a.source_reference in ^source_references and
              (a.sales_order_id != ^order.id or a.event_id != ^order.event_id),
          limit: 1
      )

    case conflicting_attendee do
      nil ->
        :ok

      %Attendee{} ->
        manual_review(
          order,
          "attendee_source_reference_conflict",
          :attendee_source_reference_conflict,
          context
        )
    end
  end

  defp load_ticket_issues(order_id) do
    case TicketIssue
         |> Query.for_read(:list_by_order, %{sales_order_id: order_id})
         |> Ash.read(authorize?: false) do
      {:ok, issues} ->
        {:ok, Map.new(issues, &{{&1.sales_order_line_id, &1.line_item_sequence}, &1})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_expected_units(
         order,
         expected_units,
         attendees_by_source_reference,
         existing_issues,
         context
       ) do
    Enum.reduce_while(expected_units, {:ok, []}, fn unit, {:ok, acc} ->
      case link_expected_unit(
             order,
             unit,
             attendees_by_source_reference,
             existing_issues,
             context
           ) do
        {:ok, issue} ->
          {:cont, {:ok, [issue | acc]}}

        {:manual_review, _error} = manual_review_error ->
          {:halt, manual_review_error}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      other -> other
    end
  end

  defp link_expected_unit(order, unit, attendees_by_source_reference, existing_issues, context) do
    with {:ok, attendee_result} <- fetch_attendee_result(unit, attendees_by_source_reference),
         {:ok, attendee} <- load_and_validate_attendee(order, unit, attendee_result, context) do
      key = {unit.line.id, unit.sequence}

      case Map.get(existing_issues, key) do
        %TicketIssue{} = issue ->
          verify_existing_issue(order, attendee, issue, context)

        nil ->
          create_issue_and_link_attendee(order, unit, attendee, context)
      end
    end
  end

  defp fetch_attendee_result(unit, attendees_by_source_reference) do
    case Map.get(attendees_by_source_reference, unit.source_reference) do
      nil -> {:error, {:missing_attendee_for_unit, unit.source_reference}}
      attendee_result -> {:ok, attendee_result}
    end
  end

  defp load_and_validate_attendee(order, unit, attendee_result, context) do
    case Repo.get(Attendee, attendee_result.id) do
      %Attendee{} = attendee ->
        cond do
          attendee.event_id != order.event_id ->
            manual_review(order, "issuer_attendee_conflict", :issuer_attendee_conflict, context)

          attendee.source != @source_fastcheck_sales ->
            manual_review(order, "issuer_attendee_conflict", :issuer_attendee_conflict, context)

          attendee.source_reference != unit.source_reference ->
            manual_review(order, "issuer_attendee_conflict", :issuer_attendee_conflict, context)

          attendee.scan_eligibility != @scan_eligibility_active ->
            manual_review(order, "issuer_attendee_conflict", :issuer_attendee_conflict, context)

          is_nil(attendee.ticket_code) or attendee.ticket_code == "" ->
            manual_review(order, "issuer_attendee_conflict", :issuer_attendee_conflict, context)

          true ->
            {:ok, attendee}
        end

      nil ->
        {:error, {:missing_attendee_for_unit, unit.source_reference}}
    end
  end

  defp verify_existing_issue(order, attendee, issue, context) do
    cond do
      issue.attendee_id != attendee.id ->
        manual_review(
          order,
          "issuer_ticket_issue_conflict",
          :issuer_ticket_issue_conflict,
          context
        )

      issue.ticket_code != attendee.ticket_code ->
        manual_review(
          order,
          "issuer_ticket_issue_conflict",
          :issuer_ticket_issue_conflict,
          context
        )

      attendee.sales_ticket_issue_id not in [nil, issue.id] ->
        manual_review(
          order,
          "issuer_ticket_issue_conflict",
          :issuer_ticket_issue_conflict,
          context
        )

      true ->
        with {:ok, _attendee} <- ensure_attendee_backlink(attendee, issue) do
          {:ok, issue}
        end
    end
  end

  defp create_issue_and_link_attendee(order, unit, attendee, context) do
    if attendee.sales_ticket_issue_id do
      manual_review(order, "issuer_ticket_issue_conflict", :issuer_ticket_issue_conflict, context)
    else
      qr_token = QrPayload.generate_qr_token()
      delivery_token = DeliveryToken.generate()

      attrs = %{
        sales_order_id: order.id,
        sales_order_line_id: unit.line.id,
        line_item_sequence: unit.sequence,
        attendee_id: attendee.id,
        ticket_code: attendee.ticket_code,
        qr_token_hash: qr_token.hash,
        delivery_token_hash: delivery_token.hash,
        delivery_token_expires_at: delivery_token.expires_at
      }

      TicketIssue
      |> Changeset.for_create(:create_issued_link, attrs, actor: context.actor, context: context)
      |> ash_create(context)
      |> case do
        {:ok, issue} ->
          with {:ok, _attendee} <- ensure_attendee_backlink(attendee, issue) do
            {:ok, issue}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_attendee_backlink(
         %Attendee{sales_ticket_issue_id: issue_id} = attendee,
         %TicketIssue{
           id: issue_id
         }
       )
       when not is_nil(issue_id),
       do: {:ok, attendee}

  defp ensure_attendee_backlink(
         %Attendee{sales_ticket_issue_id: nil} = attendee,
         %TicketIssue{} = issue
       ) do
    attendee
    |> Attendee.changeset(%{sales_ticket_issue_id: issue.id})
    |> Repo.update()
  end

  defp ensure_attendee_backlink(%Attendee{} = attendee, _issue),
    do: {:error, {:attendee_ticket_issue_conflict, attendee.id}}

  defp ensure_all_units_linked(expected_units, linked_issues) do
    if length(expected_units) == length(linked_issues) do
      :ok
    else
      {:error, :ticket_issue_count_mismatch}
    end
  end

  defp mark_order_ticket_issued(%Order{} = order, context) do
    order
    |> Changeset.for_update(:mark_ticket_issued, %{}, actor: context.actor, context: context)
    |> ash_update(context)
  end

  defp build_ticket_issue_result(
         %Order{} = original_order,
         %Order{} = updated_order,
         attendee_results,
         linked_issues,
         complete_existing_issue_set?
       ) do
    status =
      if original_order.status == "ticket_issued" and complete_existing_issue_set? and
           Enum.all?(attendee_results, &(&1.action == :reused)) do
        :already_issued
      else
        :ticket_issued
      end

    %{
      order_id: updated_order.id,
      status: status,
      attendee_count: length(attendee_results),
      ticket_issue_count: length(linked_issues),
      ticket_issues:
        Enum.map(linked_issues, fn issue ->
          source_reference =
            source_reference(
              updated_order.id,
              issue.sales_order_line_id,
              issue.line_item_sequence
            )

          %{id: issue.id, attendee_id: issue.attendee_id, source_reference: source_reference}
        end)
    }
  end

  defp manual_review(%Order{} = order, reason_string, reason_atom, context) do
    case order
         |> Changeset.for_update(
           :mark_manual_review,
           %{manual_review_reason: reason_string},
           reason: reason_string,
           actor: context.actor,
           context: context
         )
         |> ash_update(context) do
      {:ok, _order} -> {:manual_review, {:error, {:manual_review_required, reason_atom}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_existing_issue_set?(expected_units, existing_issues) do
    Enum.all?(expected_units, fn unit ->
      Map.has_key?(existing_issues, {unit.line.id, unit.sequence})
    end)
  end

  defp ash_create(changeset, context) do
    case Ash.create(changeset,
           authorize?: false,
           context: context,
           return_notifications?: true
         ) do
      {:ok, record, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, record}

      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ash_update(changeset, context) do
    case Ash.update(changeset,
           authorize?: false,
           context: context,
           return_notifications?: true
         ) do
      {:ok, record, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, record}

      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp system_actor do
    %{actor_type: :system, actor_id: "system"}
  end

  defp issuer_context(opts) do
    actor =
      opts
      |> Keyword.get(:actor, system_actor())
      |> Map.put_new(:actor_type, :system)
      |> Map.put_new(:actor_id, "system")
      |> maybe_put(:correlation_id, Keyword.get(opts, :correlation_id))
      |> maybe_put(:idempotency_key, Keyword.get(opts, :idempotency_key))

    %{
      actor: actor,
      correlation_id: Keyword.get(opts, :correlation_id),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp create_or_reuse_attendee(%Order{} = order, %OrderLine{} = line, source_reference, context) do
    case get_attendee_by_source_reference(source_reference) do
      nil ->
        insert_attendee(order, line, source_reference, context)

      %Attendee{} = attendee ->
        if attendee.sales_order_id == order.id and attendee.event_id == order.event_id do
          {:ok, attendee_result(attendee, source_reference, :reused)}
        else
          manual_review(
            order,
            "attendee_source_reference_conflict",
            :attendee_source_reference_conflict,
            context
          )
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

  defp insert_attendee(
         order,
         line,
         source_reference,
         context,
         attempts_left \\ @ticket_code_attempts
       )

  defp insert_attendee(_order, _line, _source_reference, _context, 0),
    do: {:error, {:manual_review_required, :ticket_code_collision}}

  defp insert_attendee(
         %Order{} = order,
         %OrderLine{} = line,
         source_reference,
         context,
         attempts_left
       ) do
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
            insert_attendee(order, line, source_reference, context, attempts_left - 1)

          constraint_error?(changeset, :source_reference, :unique) ->
            case get_attendee_by_source_reference(source_reference) do
              %Attendee{} = attendee
              when attendee.sales_order_id == order.id and attendee.event_id == order.event_id ->
                {:ok, attendee_result(attendee, source_reference, :reused)}

              _other ->
                manual_review(
                  order,
                  "attendee_source_reference_conflict",
                  :attendee_source_reference_conflict,
                  context
                )
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

  defp normalize_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp maybe_bump_mobile_sync_version(
         %Order{} = order,
         attendee_results,
         %{status: :ticket_issued},
         opts
       ) do
    aggregator = Keyword.get(opts, :mobile_sync_version_aggregator, MobileSyncVersionAggregator)
    ticket_codes = Enum.map(attendee_results, & &1.ticket_code)
    attendee_ids = Enum.map(attendee_results, & &1.id)

    case aggregator.after_attendees_created(order.event_id, ticket_codes,
           attendee_ids: attendee_ids,
           source: :sales_issuer,
           skip_cache_invalidation: true
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mobile_sync_version_aggregation_failed, reason}}
    end
  end

  defp maybe_bump_mobile_sync_version(%Order{}, _attendee_results, _ticket_issue_result, _opts),
    do: :ok

  defp maybe_invalidate_mobile_sync_caches(order_id, ticket_issues, _opts) do
    case ticket_issues do
      [%{attendee_id: attendee_id} | _] ->
        attendee_ids = Enum.map(ticket_issues, & &1.attendee_id)

        attendees =
          Repo.all(
            from a in Attendee,
              where: a.id in ^attendee_ids,
              select: %{id: a.id, event_id: a.event_id, ticket_code: a.ticket_code}
          )

        case attendees do
          [%{event_id: event_id} | _] ->
            ticket_codes = Enum.map(attendees, & &1.ticket_code)
            attendee_ids = Enum.map(attendees, & &1.id)

            _ =
              MobileSyncVersionAggregator.invalidate_attendees_created_caches(
                event_id,
                ticket_codes,
                attendee_ids: attendee_ids,
                source: :sales_issuer
              )

            :ok

          [] ->
            _ = attendee_id
            :ok
        end

      [] ->
        _ = order_id
        :ok
    end
  end
end
