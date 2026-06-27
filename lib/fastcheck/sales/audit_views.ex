defmodule FastCheck.Sales.AuditViews do
  @moduledoc """
  Redacted, paginated Sales audit timelines.

  These reads are intentionally safe summaries. Raw provider payloads, buyer PII,
  ticket codes, token hashes, authorization URLs, and access codes are not
  returned.
  """

  import Ecto.Query

  alias FastCheck.Observability.Redactor
  alias FastCheck.Repo

  @default_limit 25
  @max_limit 50
  @entity_types %{
    "order" => "Order",
    "checkout_session" => "CheckoutSession",
    "payment_attempt" => "PaymentAttempt",
    "payment_event" => "PaymentEvent",
    "ticket_issue" => "TicketIssue",
    "delivery_attempt" => "DeliveryAttempt",
    "conversation" => "Conversation",
    "state_transition" => "StateTransition",
    "attendee_invalidation_event" => "AttendeeInvalidationEvent"
  }

  @doc "Returns a safe timeline page for an allowed entity type and id."
  def timeline(entity_type, entity_id, opts \\ []) do
    with {:ok, transition_entity_type} <- transition_entity_type(entity_type),
         {:ok, id} <- parse_id(entity_id) do
      limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)
      page = opts |> Keyword.get(:page, 1) |> clamp(1, 10_000)
      offset = (page - 1) * limit

      entries =
        entity_type
        |> timeline_entries(id, transition_entity_type)
        |> Enum.sort(&entry_before?/2)
        |> Enum.drop(offset)
        |> Enum.take(limit + 1)
        |> Enum.map(&safe_entry/1)

      {visible_entries, next_page} =
        if length(entries) > limit do
          {Enum.take(entries, limit), page + 1}
        else
          {entries, nil}
        end

      {:ok, %{entries: visible_entries, page: page, limit: limit, next_page: next_page}}
    end
  end

  defp transition_entity_type(entity_type) when is_binary(entity_type) do
    case Map.fetch(@entity_types, entity_type) do
      {:ok, transition_entity_type} -> {:ok, transition_entity_type}
      :error -> {:error, :invalid_entity_type}
    end
  end

  defp transition_entity_type(_), do: {:error, :invalid_entity_type}

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_entity_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_entity_id}

  defp timeline_entries(entity_type, id, transition_entity_type) do
    summary_entries(entity_type, id) ++ transition_entries(transition_entity_type, id)
  end

  defp summary_entries("payment_attempt", id), do: Repo.all(payment_attempt_summary_query(id))
  defp summary_entries("payment_event", id), do: Repo.all(payment_event_summary_query(id))
  defp summary_entries("ticket_issue", id), do: Repo.all(ticket_issue_summary_query(id))
  defp summary_entries("delivery_attempt", id), do: Repo.all(delivery_attempt_summary_query(id))
  defp summary_entries("checkout_session", id), do: Repo.all(checkout_session_summary_query(id))
  defp summary_entries("conversation", id), do: Repo.all(conversation_summary_query(id))

  defp summary_entries("attendee_invalidation_event", id),
    do: Repo.all(attendee_invalidation_summary_query(id))

  defp summary_entries(_entity_type, _id), do: []

  defp transition_entries(entity_type, id) do
    entity_id = Integer.to_string(id)

    "sales_state_transitions"
    |> where([s], s.entity_type == ^entity_type and s.entity_id == ^entity_id)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> select([s], %{
      sort_id: s.id,
      timestamp: s.inserted_at,
      entity_type: s.entity_type,
      entity_id: s.entity_id,
      from_state: s.from_state,
      to_state: s.to_state,
      reason_code: s.reason,
      actor_type: s.actor_type,
      actor_id: s.actor_id,
      source: s.source,
      correlation_id: s.correlation_id,
      idempotency_key: s.idempotency_key,
      metadata: s.metadata
    })
    |> Repo.all()
  end

  defp payment_attempt_summary_query(id) do
    from p in "sales_payment_attempts",
      where: p.id == ^id,
      select: %{
        sort_id: p.id,
        timestamp: p.inserted_at,
        entity_type: "PaymentAttempt",
        entity_id: fragment("?::text", p.id),
        from_state: nil,
        to_state: p.status,
        reason_code: p.manual_review_reason,
        actor_type: "system",
        actor_id: nil,
        source: "payment_attempt.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('provider', ?, 'status', ?, 'provider_status', ?, 'amount_cents', ?, 'currency', ?)",
            p.provider,
            p.status,
            p.provider_status,
            p.amount_cents,
            p.currency
          )
      }
  end

  defp payment_event_summary_query(id) do
    from e in "sales_payment_events",
      where: e.id == ^id,
      select: %{
        sort_id: e.id,
        timestamp: e.inserted_at,
        entity_type: "PaymentEvent",
        entity_id: fragment("?::text", e.id),
        from_state: nil,
        to_state: e.processing_status,
        reason_code: e.last_processing_error,
        actor_type: "system",
        actor_id: nil,
        source: "payment_event.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('provider', ?, 'event_type', ?, 'signature_valid', ?, 'processing_status', ?)",
            e.provider,
            e.event_type,
            e.signature_valid,
            e.processing_status
          )
      }
  end

  defp ticket_issue_summary_query(id) do
    from t in "sales_ticket_issues",
      where: t.id == ^id,
      select: %{
        sort_id: t.id,
        timestamp: t.inserted_at,
        entity_type: "TicketIssue",
        entity_id: fragment("?::text", t.id),
        from_state: nil,
        to_state: t.status,
        reason_code: t.revocation_reason,
        actor_type: "system",
        actor_id: nil,
        source: "ticket_issue.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('sales_order_id', ?, 'status', ?, 'scanner_status', ?, 'issued_at', ?, 'revoked_at', ?)",
            t.sales_order_id,
            t.status,
            t.scanner_status,
            t.issued_at,
            t.revoked_at
          )
      }
  end

  defp delivery_attempt_summary_query(id) do
    from d in "sales_delivery_attempts",
      where: d.id == ^id,
      select: %{
        sort_id: d.id,
        timestamp: d.inserted_at,
        entity_type: "DeliveryAttempt",
        entity_id: fragment("?::text", d.id),
        from_state: nil,
        to_state: d.status,
        reason_code: d.failure_reason,
        actor_type: "system",
        actor_id: nil,
        source: "delivery_attempt.summary",
        correlation_id: d.correlation_id,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('sales_order_id', ?, 'ticket_issue_id', ?, 'channel', ?, 'provider', ?, 'status', ?, 'template_name', ?, 'fallback_channel', ?, 'within_whatsapp_window', ?)",
            d.sales_order_id,
            d.ticket_issue_id,
            d.channel,
            d.provider,
            d.status,
            d.template_name,
            d.fallback_channel,
            d.within_whatsapp_window
          )
      }
  end

  defp checkout_session_summary_query(id) do
    from c in "sales_checkout_sessions",
      where: c.id == ^id,
      select: %{
        sort_id: c.id,
        timestamp: c.inserted_at,
        entity_type: "CheckoutSession",
        entity_id: fragment("?::text", c.id),
        from_state: nil,
        to_state: c.status,
        reason_code: nil,
        actor_type: "system",
        actor_id: nil,
        source: "checkout_session.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('sales_order_id', ?, 'status', ?, 'expires_at', ?, 'released_at', ?, 'expired_at', ?)",
            c.sales_order_id,
            c.status,
            c.expires_at,
            c.released_at,
            c.expired_at
          )
      }
  end

  defp conversation_summary_query(id) do
    from c in "sales_conversations",
      where: c.id == ^id,
      select: %{
        sort_id: c.id,
        timestamp: c.inserted_at,
        entity_type: "Conversation",
        entity_id: fragment("?::text", c.id),
        from_state: nil,
        to_state: c.state,
        reason_code: c.handoff_reason,
        actor_type: "system",
        actor_id: nil,
        source: "conversation.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('state', ?, 'preferred_language', ?, 'needs_human', ?, 'last_message_at', ?)",
            c.state,
            c.preferred_language,
            c.needs_human,
            c.last_message_at
          )
      }
  end

  defp attendee_invalidation_summary_query(id) do
    from i in "attendee_invalidation_events",
      where: i.id == ^id,
      select: %{
        sort_id: i.id,
        timestamp: i.inserted_at,
        entity_type: "AttendeeInvalidationEvent",
        entity_id: fragment("?::text", i.id),
        from_state: nil,
        to_state: i.change_type,
        reason_code: i.reason_code,
        actor_type: "system",
        actor_id: nil,
        source: "attendee_invalidation.summary",
        correlation_id: nil,
        idempotency_key: nil,
        metadata:
          fragment(
            "jsonb_build_object('event_id', ?, 'attendee_id', ?, 'change_type', ?, 'reason_code', ?, 'effective_at', ?)",
            i.event_id,
            i.attendee_id,
            i.change_type,
            i.reason_code,
            i.effective_at
          )
      }
  end

  defp safe_entry(entry) do
    %{
      timestamp: entry.timestamp,
      entity_type: entry.entity_type,
      entity_id: entry.entity_id,
      from_state: entry.from_state,
      to_state: entry.to_state,
      reason_code: entry.reason_code,
      actor_type: entry.actor_type,
      actor_id: safe_actor_id(entry.actor_id),
      source: entry.source,
      correlation_id: entry.correlation_id,
      idempotency_key: safe_idempotency_key(entry.idempotency_key),
      metadata: entry.metadata |> normalize_metadata() |> Redactor.safe_metadata()
    }
  end

  defp entry_before?(left, right) do
    case NaiveDateTime.compare(to_naive(left.timestamp), to_naive(right.timestamp)) do
      :gt -> true
      :lt -> false
      :eq -> left.sort_id >= right.sort_id
    end
  end

  defp to_naive(%NaiveDateTime{} = timestamp), do: timestamp
  defp to_naive(%DateTime{} = timestamp), do: DateTime.to_naive(timestamp)

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_metadata(_), do: %{}

  defp safe_actor_id(nil), do: nil

  defp safe_actor_id(actor_id) when is_binary(actor_id) do
    cond do
      String.contains?(actor_id, "@") -> Redactor.redact_email(actor_id)
      String.match?(actor_id, ~r/^\+?[0-9][0-9\s().-]+$/) -> Redactor.redact_phone(actor_id)
      true -> actor_id
    end
  end

  defp safe_actor_id(actor_id), do: actor_id

  defp safe_idempotency_key(nil), do: nil
  defp safe_idempotency_key(_), do: Redactor.filtered()

  defp clamp(value, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp clamp(_value, min, _max), do: min
end
