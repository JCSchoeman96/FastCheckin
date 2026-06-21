defmodule FastCheck.Sales.ManualReview do
  @moduledoc """
  Bounded service boundary for Sales manual-review operations.

  LiveViews and other UI entrypoints must call this module instead of writing
  review audit rows, mutating Sales state, or enqueueing retry jobs directly.
  """

  import Ecto.Query

  alias Ash.Changeset
  alias Ash.Query
  alias FastCheck.Observability.Redactor
  alias FastCheck.Repo
  alias FastCheck.Sales.ManualReviewAction
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.PaymentAttempt
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.Workers.IssueTicketsWorker
  alias Phoenix.PubSub

  @default_limit 50
  @max_limit 50
  @pubsub FastCheck.PubSub
  @topic "sales:manual_review"
  @state_changing_actions ~w(
    retry_payment_verification
    retry_ticket_issuance
    hold_for_investigation
    close_no_fulfillment
    return_to_fulfillment_queue
    return_held_to_manual_review
  )
  @reason_codes @state_changing_actions ++
                  ~w(operator_note operator_assigned operator_unassigned)

  @order_queue_statuses ~w(manual_review manual_review_held issuance_retry_queued)

  @doc "Returns a bounded, safe manual-review queue."
  def list_queue(filters \\ %{}, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)
    event_id = parse_optional_integer(Map.get(filters, "event_id") || Map.get(filters, :event_id))

    entries =
      [
        order_queue_rows(event_id, limit),
        payment_attempt_queue_rows(event_id, limit),
        ticket_issue_queue_rows(event_id, limit)
      ]
      |> List.flatten()
      |> Enum.sort(&queue_row_before?/2)
      |> Enum.take(limit)
      |> Enum.map(&safe_queue_row/1)

    %{entries: entries, limit: limit}
  end

  def get_context(subject_type, subject_id, _opts \\ []) do
    get_context_for(subject_type, subject_id)
  end

  def assign(subject_type, subject_id, actor, attrs) do
    audit_only(subject_type, subject_id, actor, attrs, "assign_to_self")
  end

  def unassign(subject_type, subject_id, actor, attrs) do
    audit_only(subject_type, subject_id, actor, attrs, "unassign")
  end

  def add_note(subject_type, subject_id, actor, attrs) do
    audit_only(subject_type, subject_id, actor, attrs, "add_note")
  end

  def retry_payment_verification(payment_attempt_id, actor, attrs) do
    with {:ok, reason_code} <- require_reason(attrs, "retry_payment_verification"),
         {:ok, attempt} <- load_payment_attempt(payment_attempt_id),
         {:ok, order} <- load_order(attempt.sales_order_id),
         :ok <- require_status(attempt.status, ["manual_review"]) do
      run_transaction(fn ->
        ash_actor = ash_actor(actor, order.event_id)

        with {:ok, updated_attempt} <-
               transition_payment_attempt(
                 attempt,
                 :queue_verification_retry,
                 reason_code,
                 ash_actor
               ),
             {:ok, review_action} <-
               record_action(%{
                 subject_type: "payment_attempt",
                 subject_id: Integer.to_string(attempt.id),
                 sales_order_id: order.id,
                 payment_attempt_id: attempt.id,
                 action: "retry_payment_verification",
                 reason_code: reason_code,
                 actor: actor,
                 previous_status: attempt.status,
                 new_status: updated_attempt.status,
                 metadata: %{payment_attempt_id: attempt.id, order_id: order.id}
               }),
             {:ok, _job} <-
               VerifyPaymentWorker.new(%{
                 "payment_attempt_id" => attempt.id,
                 "correlation_id" => review_action.correlation_id
               })
               |> Oban.insert() do
          {:ok, review_action}
        end
      end)
      |> commit_then_broadcast()
    end
  end

  def retry_ticket_issuance(order_id, actor, attrs) do
    with {:ok, reason_code} <- require_reason(attrs, "retry_ticket_issuance"),
         {:ok, order} <- load_order(order_id),
         :ok <- require_status(order.status, ["manual_review"]) do
      run_transaction(fn ->
        ash_actor = ash_actor(actor, order.event_id)

        with {:ok, updated_order} <-
               transition_order(order, :queue_issuance_retry, reason_code, ash_actor),
             {:ok, review_action} <-
               record_action(%{
                 subject_type: "order",
                 subject_id: Integer.to_string(order.id),
                 sales_order_id: order.id,
                 action: "retry_ticket_issuance",
                 reason_code: reason_code,
                 actor: actor,
                 previous_status: order.status,
                 new_status: updated_order.status,
                 metadata: %{order_id: order.id}
               }),
             {:ok, _job} <-
               IssueTicketsWorker.new(%{
                 "sales_order_id" => order.id,
                 "idempotency_key" => "manual-review:issue:#{order.id}",
                 "correlation_id" => review_action.correlation_id
               })
               |> Oban.insert() do
          {:ok, review_action}
        end
      end)
      |> commit_then_broadcast()
    end
  end

  def hold_for_investigation(order_id, actor, attrs) do
    transition_order_review_action(
      order_id,
      actor,
      attrs,
      "hold_for_investigation",
      :hold_manual_review,
      note_required?: false
    )
  end

  def close_no_fulfillment(order_id, actor, attrs) do
    transition_order_review_action(
      order_id,
      actor,
      attrs,
      "close_no_fulfillment",
      :close_no_fulfillment,
      note_required?: true
    )
  end

  def return_held_to_manual_review(order_id, actor, attrs) do
    transition_order_review_action(
      order_id,
      actor,
      attrs,
      "return_held_to_manual_review",
      :return_held_to_manual_review,
      note_required?: false
    )
  end

  def return_to_fulfillment_queue(order_id, actor, attrs) do
    with {:ok, reason_code} <- require_reason(attrs, "return_to_fulfillment_queue"),
         {:ok, note} <- require_note(attrs),
         {:ok, order} <- load_order(order_id),
         :ok <- safe_fulfillment_return?(order) do
      run_transaction(fn ->
        ash_actor = ash_actor(actor, order.event_id)

        with {:ok, updated_order} <-
               transition_order(order, :return_to_fulfillment_queue, reason_code, ash_actor) do
          record_action(%{
            subject_type: "order",
            subject_id: Integer.to_string(order.id),
            sales_order_id: order.id,
            action: "return_to_fulfillment_queue",
            reason_code: reason_code,
            note: note,
            actor: actor,
            previous_status: order.status,
            new_status: updated_order.status,
            metadata: %{order_id: order.id}
          })
        end
      end)
      |> commit_then_broadcast()
    else
      {:error, :unsafe_manual_review_transition} = error ->
        maybe_record_blocked_return(order_id, actor, attrs)
        error

      other ->
        other
    end
  end

  defp transition_order_review_action(order_id, actor, attrs, action, ash_action, opts) do
    with {:ok, reason_code} <- require_reason(attrs, action),
         {:ok, note} <- maybe_require_note(attrs, Keyword.get(opts, :note_required?, false)),
         {:ok, order} <- load_order(order_id) do
      run_transaction(fn ->
        ash_actor = ash_actor(actor, order.event_id)

        with {:ok, updated_order} <- transition_order(order, ash_action, reason_code, ash_actor) do
          record_action(%{
            subject_type: "order",
            subject_id: Integer.to_string(order.id),
            sales_order_id: order.id,
            action: action,
            reason_code: reason_code,
            note: note,
            actor: actor,
            previous_status: order.status,
            new_status: updated_order.status,
            metadata: %{order_id: order.id}
          })
        end
      end)
      |> commit_then_broadcast()
    end
  end

  defp audit_only(subject_type, subject_id, actor, attrs, action) do
    with {:ok, subject_id} <- parse_integer(subject_id),
         {:ok, order} <- load_order_for_subject(subject_type, subject_id),
         {:ok, reason_code} <- require_audit_reason(attrs, default_reason(action)),
         {:ok, note} <- optional_note(attrs) do
      record_action(%{
        subject_type: subject_type,
        subject_id: Integer.to_string(subject_id),
        sales_order_id: order.id,
        action: action,
        reason_code: reason_code,
        note: note,
        actor: actor,
        previous_status: order.status,
        new_status: order.status,
        metadata: %{order_id: order.id}
      })
      |> commit_then_broadcast()
    end
  end

  defp record_action(attrs) do
    actor = Map.fetch!(attrs, :actor)
    actor_id = actor_id(actor)

    correlation_id =
      Map.get(attrs, :correlation_id) || "manual-review-#{System.unique_integer([:positive])}"

    create_attrs = %{
      subject_type: attrs.subject_type,
      subject_id: attrs.subject_id,
      sales_order_id: Map.get(attrs, :sales_order_id),
      payment_attempt_id: Map.get(attrs, :payment_attempt_id),
      payment_event_id: Map.get(attrs, :payment_event_id),
      ticket_issue_id: Map.get(attrs, :ticket_issue_id),
      checkout_session_id: Map.get(attrs, :checkout_session_id),
      action: attrs.action,
      reason_code: Map.get(attrs, :reason_code),
      note: Map.get(attrs, :note),
      actor_type: "dashboard_user",
      actor_id: actor_id,
      actor_label: Map.get(actor, :username) || Map.get(actor, "username") || actor_id,
      previous_status: Map.get(attrs, :previous_status),
      new_status: Map.get(attrs, :new_status),
      metadata: Map.get(attrs, :metadata, %{}) |> Redactor.safe_metadata(),
      correlation_id: correlation_id
    }

    ManualReviewAction
    |> Changeset.for_create(:record_action, create_attrs,
      actor: %{actor_type: :admin, actor_id: actor_id}
    )
    |> Ash.create()
  end

  defp transition_order(order, action, reason, actor) do
    order
    |> Changeset.for_update(action, %{}, actor: actor, reason: reason)
    |> Ash.update(authorize?: true)
  end

  defp transition_payment_attempt(attempt, action, reason, actor) do
    attempt
    |> Changeset.for_update(action, %{}, actor: actor, reason: reason)
    |> Ash.update(authorize?: true)
  end

  defp safe_fulfillment_return?(order) do
    with :ok <- require_status(order.status, ["manual_review", "manual_review_held"]),
         {:ok, latest_attempt} <- latest_payment_attempt(order.id),
         :ok <- require_status(latest_attempt.status, ["verified_success"]),
         :ok <- require_payment_amount(latest_attempt, order),
         :ok <- require_paid_checkout(order.id),
         :ok <- require_no_issued_tickets(order.id) do
      :ok
    else
      _ -> {:error, :unsafe_manual_review_transition}
    end
  end

  defp latest_payment_attempt(order_id) do
    case Repo.one(
           from p in "sales_payment_attempts",
             where: p.sales_order_id == ^order_id,
             order_by: [desc: p.inserted_at, desc: p.id],
             limit: 1,
             select: %{
               id: p.id,
               status: p.status,
               amount_cents: p.amount_cents,
               currency: p.currency,
               provider_reference: p.provider_reference
             }
         ) do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt}
    end
  end

  defp require_payment_amount(attempt, order) do
    if attempt.amount_cents == order.total_amount_cents and attempt.currency == order.currency do
      :ok
    else
      {:error, :unsafe_manual_review_transition}
    end
  end

  defp require_paid_checkout(order_id) do
    case Repo.one(
           from c in "sales_checkout_sessions",
             where: c.sales_order_id == ^order_id,
             select: c.status
         ) do
      "paid" -> :ok
      _ -> {:error, :unsafe_manual_review_transition}
    end
  end

  defp require_no_issued_tickets(order_id) do
    if Repo.exists?(
         from t in "sales_ticket_issues",
           where: t.sales_order_id == ^order_id and t.status == "issued"
       ) do
      {:error, :unsafe_manual_review_transition}
    else
      :ok
    end
  end

  defp maybe_record_blocked_return(order_id, actor, attrs) do
    with {:ok, order} <- load_order(order_id),
         {:ok, reason_code} <- require_reason(attrs, "return_to_fulfillment_queue") do
      record_action(%{
        subject_type: "order",
        subject_id: Integer.to_string(order.id),
        sales_order_id: order.id,
        action: "blocked_return_to_fulfillment_queue",
        reason_code: reason_code,
        actor: actor,
        previous_status: order.status,
        new_status: order.status,
        metadata: %{order_id: order.id, blocked: true}
      })
      |> commit_then_broadcast()
    else
      _ -> :ok
    end
  end

  defp load_order_for_subject("order", id), do: load_order(id)

  defp load_order_for_subject("payment_attempt", id) do
    with {:ok, attempt} <- load_payment_attempt(id), do: load_order(attempt.sales_order_id)
  end

  defp load_order_for_subject("ticket_issue", id) do
    with {:ok, issue} <- load_ticket_issue(id), do: load_order(issue.sales_order_id)
  end

  defp load_order_for_subject(_subject_type, _id), do: {:error, :invalid_subject}

  defp load_order(id) do
    with {:ok, id} <- parse_integer(id) do
      Order
      |> Query.for_read(:get_by_id, %{id: id})
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, order} -> {:ok, order}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp load_payment_attempt(id) do
    with {:ok, id} <- parse_integer(id) do
      case Repo.one(
             from p in PaymentAttempt,
               where: p.id == ^id
           ) do
        nil -> {:error, :not_found}
        attempt -> {:ok, attempt}
      end
    end
  end

  defp load_ticket_issue(id) do
    with {:ok, id} <- parse_integer(id) do
      case Repo.one(
             from t in "sales_ticket_issues",
               where: t.id == ^id,
               select: %{
                 id: t.id,
                 sales_order_id: t.sales_order_id,
                 status: t.status,
                 scanner_status: t.scanner_status,
                 ticket_code: t.ticket_code
               }
           ) do
        nil -> {:error, :not_found}
        issue -> {:ok, issue}
      end
    end
  end

  defp get_context_for("order", subject_id) do
    with {:ok, subject_id} <- parse_integer(subject_id),
         {:ok, order} <- load_order(subject_id) do
      {:ok, build_order_context(order, "order", Integer.to_string(order.id))}
    end
  end

  defp get_context_for("payment_attempt", subject_id) do
    with {:ok, subject_id} <- parse_integer(subject_id),
         {:ok, attempt} <- load_payment_attempt(subject_id),
         {:ok, order} <- load_order(attempt.sales_order_id) do
      {:ok,
       order
       |> build_order_context("payment_attempt", Integer.to_string(attempt.id))
       |> Map.put(:payment_attempt_id, attempt.id)
       |> Map.put(:payment_summary, safe_payment_summary(attempt))
       |> Map.put(:can_retry_payment?, attempt.status == "manual_review")
       |> Map.put(:timeline, timeline("payment_attempt", Integer.to_string(attempt.id)))}
    end
  end

  defp get_context_for("ticket_issue", subject_id) do
    with {:ok, subject_id} <- parse_integer(subject_id),
         {:ok, issue} <- load_ticket_issue(subject_id),
         {:ok, order} <- load_order(issue.sales_order_id) do
      {:ok,
       order
       |> build_order_context("ticket_issue", Integer.to_string(issue.id))
       |> Map.put(:ticket_issue_summary, safe_ticket_issue_summary(issue))
       |> Map.put(:timeline, timeline("ticket_issue", Integer.to_string(issue.id)))}
    end
  end

  defp get_context_for(_subject_type, _subject_id), do: {:error, :invalid_subject}

  defp build_order_context(order, subject_type, subject_id) do
    order
    |> safe_order_context()
    |> Map.put(:subject_type, subject_type)
    |> Map.put(:subject_id, subject_id)
    |> Map.merge(payment_context(order.id))
    |> Map.merge(ticket_review_context(order.id))
    |> Map.put(:timeline, timeline(subject_type, subject_id))
  end

  defp order_queue_rows(event_id, source_limit) do
    "sales_orders"
    |> where([o], o.status in ^@order_queue_statuses)
    |> maybe_filter_event(event_id)
    |> order_by([o], desc: o.inserted_at, desc: o.id)
    |> limit(^source_limit)
    |> select([o], %{
      subject_type: "order",
      subject_id: fragment("?::text", o.id),
      sales_order_id: o.id,
      order_public_reference: o.public_reference,
      event_id: o.event_id,
      current_status: o.status,
      reason_code: o.manual_review_reason,
      buyer_email_private: o.buyer_email,
      buyer_phone_private: o.buyer_phone,
      inserted_at: o.inserted_at,
      sort_id: o.id
    })
    |> Repo.all()
  end

  defp payment_attempt_queue_rows(event_id, source_limit) do
    from(p in "sales_payment_attempts",
      join: o in "sales_orders",
      on: o.id == p.sales_order_id,
      where: p.status == "manual_review",
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^source_limit,
      select: %{
        subject_type: "payment_attempt",
        subject_id: fragment("?::text", p.id),
        sales_order_id: o.id,
        order_public_reference: o.public_reference,
        event_id: o.event_id,
        current_status: p.status,
        reason_code: p.manual_review_reason,
        buyer_email_private: o.buyer_email,
        buyer_phone_private: o.buyer_phone,
        inserted_at: p.inserted_at,
        sort_id: p.id
      }
    )
    |> maybe_filter_joined_event(event_id)
    |> Repo.all()
  end

  defp ticket_issue_queue_rows(event_id, source_limit) do
    from(t in "sales_ticket_issues",
      join: o in "sales_orders",
      on: o.id == t.sales_order_id,
      where: t.status == "manual_review",
      order_by: [desc: t.inserted_at, desc: t.id],
      limit: ^source_limit,
      select: %{
        subject_type: "ticket_issue",
        subject_id: fragment("?::text", t.id),
        sales_order_id: o.id,
        order_public_reference: o.public_reference,
        event_id: o.event_id,
        current_status: t.status,
        reason_code: o.manual_review_reason,
        buyer_email_private: o.buyer_email,
        buyer_phone_private: o.buyer_phone,
        inserted_at: t.inserted_at,
        sort_id: t.id
      }
    )
    |> maybe_filter_joined_event(event_id)
    |> Repo.all()
  end

  defp queue_row_before?(left, right) do
    case NaiveDateTime.compare(
           normalize_queue_timestamp(left.inserted_at),
           normalize_queue_timestamp(right.inserted_at)
         ) do
      :gt -> true
      :lt -> false
      :eq -> left.sort_id >= right.sort_id
    end
  end

  defp normalize_queue_timestamp(%DateTime{} = value), do: DateTime.to_naive(value)
  defp normalize_queue_timestamp(%NaiveDateTime{} = value), do: value

  defp payment_context(order_id) do
    case latest_payment_attempt(order_id) do
      {:ok, attempt} ->
        %{
          payment_attempt_id: attempt.id,
          payment_summary: safe_payment_summary(attempt),
          can_retry_payment?: attempt.status == "manual_review"
        }

      _ ->
        %{
          payment_attempt_id: nil,
          payment_summary: nil,
          can_retry_payment?: false
        }
    end
  end

  defp ticket_review_context(order_id) do
    issues =
      Repo.all(
        from t in "sales_ticket_issues",
          where: t.sales_order_id == ^order_id and t.status == "manual_review",
          order_by: [desc: t.inserted_at, desc: t.id],
          limit: 5,
          select: %{
            id: t.id,
            status: t.status,
            scanner_status: t.scanner_status,
            ticket_code: t.ticket_code
          }
      )

    %{
      ticket_issue_summary: nil,
      ticket_issue_summaries: Enum.map(issues, &safe_ticket_issue_summary/1)
    }
  end

  defp safe_payment_summary(attempt) do
    %{
      status: attempt.status,
      amount_cents: attempt.amount_cents,
      currency: attempt.currency,
      provider_reference_masked: mask_provider_reference(attempt.provider_reference)
    }
  end

  defp safe_ticket_issue_summary(issue) do
    %{
      ticket_issue_id: issue.id,
      status: issue.status,
      scanner_status: issue.scanner_status,
      ticket_code_suffix: mask_ticket_code_suffix(issue.ticket_code)
    }
  end

  defp safe_queue_row(row) do
    %{
      subject_type: row.subject_type,
      subject_id: row.subject_id,
      sales_order_id: row.sales_order_id,
      order_public_reference: row.order_public_reference,
      event_id: row.event_id,
      current_status: row.current_status,
      reason_code: row.reason_code,
      buyer_email_masked: mask_email(row.buyer_email_private),
      buyer_phone_masked: mask_phone(row.buyer_phone_private),
      inserted_at: row.inserted_at
    }
  end

  defp safe_order_context(order) do
    %{
      sales_order_id: order.id,
      order_public_reference: order.public_reference,
      event_id: order.event_id,
      current_status: order.status,
      reason_code: order.manual_review_reason,
      buyer_email_masked: mask_email(order.buyer_email),
      buyer_phone_masked: mask_phone(order.buyer_phone),
      inserted_at: order.inserted_at,
      can_close_no_fulfillment?: order.status in ["manual_review", "manual_review_held"],
      can_return_to_fulfillment?: order.status in ["manual_review", "manual_review_held"]
    }
  end

  defp timeline(subject_type, subject_id) do
    entity_type = timeline_entity_type(subject_type)

    review_actions =
      Repo.all(
        from a in "sales_manual_review_actions",
          where: a.subject_type == ^subject_type and a.subject_id == ^subject_id,
          order_by: [desc: a.inserted_at],
          limit: 25,
          select: %{
            kind: "manual_review_action",
            action: a.action,
            reason_code: a.reason_code,
            actor_id: a.actor_id,
            previous_status: a.previous_status,
            new_status: a.new_status,
            inserted_at: a.inserted_at
          }
      )

    transitions =
      if is_nil(entity_type) do
        []
      else
        Repo.all(
          from st in "sales_state_transitions",
            where: st.entity_type == ^entity_type and st.entity_id == ^subject_id,
            order_by: [desc: st.inserted_at],
            limit: 25,
            select: %{
              kind: "state_transition",
              action: st.source,
              reason_code: st.reason,
              actor_id: st.actor_id,
              previous_status: st.from_state,
              new_status: st.to_state,
              inserted_at: st.inserted_at
            }
        )
      end

    (review_actions ++ transitions)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
    |> Enum.take(25)
  end

  defp timeline_entity_type("order"), do: "Order"
  defp timeline_entity_type("payment_attempt"), do: "PaymentAttempt"
  defp timeline_entity_type("ticket_issue"), do: "TicketIssue"
  defp timeline_entity_type(_), do: nil

  defp require_reason(attrs, default) do
    attrs
    |> get_attr("reason_code")
    |> blank_to_nil()
    |> validate_reason(default, required?: true)
  end

  defp require_audit_reason(attrs, default) do
    attrs
    |> get_attr("reason_code")
    |> blank_to_nil()
    |> validate_reason(default, required?: false)
  end

  defp validate_reason(reason, default, opts) do
    required? = Keyword.fetch!(opts, :required?)
    explicit_reason? = not is_nil(reason)
    reason = reason || default

    cond do
      required? and not explicit_reason? ->
        {:error, :reason_required}

      is_nil(reason) ->
        {:error, :reason_required}

      String.length(reason) > 80 ->
        {:error, :reason_too_long}

      reason not in @reason_codes ->
        {:error, :invalid_reason_code}

      true ->
        {:ok, reason}
    end
  end

  defp require_note(attrs) do
    case optional_note(attrs) do
      {:ok, nil} -> {:error, :note_required}
      {:ok, ""} -> {:error, :note_required}
      other -> other
    end
  end

  defp maybe_require_note(attrs, true), do: require_note(attrs)
  defp maybe_require_note(attrs, false), do: optional_note(attrs)

  defp optional_note(attrs) do
    note =
      attrs
      |> get_attr("note")
      |> case do
        nil -> nil
        value -> strip_control_characters(to_string(value))
      end

    if is_binary(note) and String.length(note) > 1000 do
      {:error, :note_too_long}
    else
      {:ok, note}
    end
  end

  defp strip_control_characters(value), do: String.replace(value, ~r/[\x00-\x1F\x7F]/u, "")

  defp require_status(status, allowed) do
    if status in allowed, do: :ok, else: {:error, :unsafe_manual_review_transition}
  end

  defp ash_actor(actor, event_id) do
    %{
      actor_type: :admin,
      actor_id: actor_id(actor),
      allowed_event_ids: [event_id]
    }
  end

  defp actor_id(actor) do
    Map.get(actor, :id) || Map.get(actor, "id") || Map.get(actor, :username) ||
      Map.get(actor, "username") || "unknown"
  end

  defp run_transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_then_broadcast({:ok, action}) do
    broadcast(action)
    {:ok, action}
  end

  defp commit_then_broadcast(other), do: other

  defp broadcast(action) do
    payload = %{
      subject_type: action.subject_type,
      subject_id: action.subject_id,
      sales_order_id: action.sales_order_id,
      action: action.action,
      actor_id: action.actor_id,
      inserted_at: action.inserted_at
    }

    try do
      PubSub.broadcast(@pubsub, @topic, {:manual_review_action, payload})
    catch
      _, _ -> :ok
    else
      _ -> :ok
    end
  end

  defp maybe_filter_event(query, nil), do: query
  defp maybe_filter_event(query, event_id), do: where(query, [o], o.event_id == ^event_id)

  defp maybe_filter_joined_event(query, nil), do: query

  defp maybe_filter_joined_event(query, event_id) do
    where(query, [_row, o], o.event_id == ^event_id)
  end

  defp parse_optional_integer(nil), do: nil

  defp parse_optional_integer(value) do
    case parse_integer(value) do
      {:ok, int} -> int
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_id}
    end
  end

  defp parse_integer(_value), do: {:error, :invalid_id}

  defp get_attr(attrs, "reason_code") do
    Map.get(attrs, "reason_code") || Map.get(attrs, :reason_code)
  end

  defp get_attr(attrs, "note") do
    Map.get(attrs, "note") || Map.get(attrs, :note)
  end

  defp get_attr(attrs, key) when is_binary(key) do
    Map.get(attrs, key)
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)

  defp default_reason("assign_to_self"), do: "operator_assigned"
  defp default_reason("unassign"), do: "operator_unassigned"
  defp default_reason("add_note"), do: "operator_note"
  defp default_reason(action), do: action

  defp mask_email(nil), do: "hidden"

  defp mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [<<first::binary-size(1), _rest::binary>>, domain] -> "#{first}***@#{domain}"
      _ -> "hidden"
    end
  end

  defp mask_phone(nil), do: "hidden"

  defp mask_phone(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    if String.length(digits) >= 4 do
      "***" <> String.slice(digits, -4, 4)
    else
      "hidden"
    end
  end

  defp mask_provider_reference(nil), do: "hidden"

  defp mask_provider_reference(reference) when is_binary(reference) do
    if String.length(reference) >= 6 do
      "***" <> String.slice(reference, -6, 6)
    else
      "hidden"
    end
  end

  defp mask_provider_reference(_), do: "hidden"

  defp mask_ticket_code_suffix(nil), do: "hidden"

  defp mask_ticket_code_suffix(ticket_code) when is_binary(ticket_code) do
    if String.length(ticket_code) >= 4 do
      "***" <> String.slice(ticket_code, -4, 4)
    else
      "hidden"
    end
  end

  defp mask_ticket_code_suffix(_), do: "hidden"

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
