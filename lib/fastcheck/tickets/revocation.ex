defmodule FastCheck.Tickets.Revocation do
  @moduledoc """
  Core Sales ticket revocation boundary for scanner visibility.

  Revokes `TicketIssue` rows, marks linked attendees `not_scannable`, appends
  invalidation events, bumps mobile sync version inside the transaction, and
  invalidates attendee caches after commit.
  """

  import Ecto.Query

  alias Ash.Changeset
  alias Ash.Query, as: AshQuery
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.ReasonCodes
  alias FastCheck.Events.MobileSyncVersionAggregator
  alias FastCheck.Observability.{Correlation, Redactor, TelemetryNames}
  alias FastCheck.Repo
  alias FastCheck.Sales.Order
  alias FastCheck.Sales.TicketIssue
  alias FastCheck.Tickets.ScannerVisibility

  @max_order_revoke_batch 50
  @pending_revoke_sources ~w(cancel cleanup cancellation system_reconciliation)

  @type revoke_result :: %{
          ticket_issue_id: integer(),
          attendee_id: integer() | nil,
          status: :revoked | :already_revoked
        }

  @doc """
  Revokes a single Sales `TicketIssue` and makes the linked attendee scanner-ineligible.
  """
  @spec revoke_ticket_issue(integer(), keyword()) ::
          {:ok, revoke_result()}
          | {:error,
             :not_found | :invalid_state | :forbidden | :reason_required | :audit_context_required}
          | {:error, {:missing_attendee, integer()}}
          | {:error, {:conflict, atom()}}
          | {:error, {:mobile_sync_version_aggregation_failed, term()}}
  def revoke_ticket_issue(ticket_issue_id, opts \\ []) when is_integer(ticket_issue_id) do
    context = build_context(opts)

    :telemetry.execute(
      TelemetryNames.ticket_revocation_started(),
      %{},
      operational_metadata(context)
    )

    with :ok <- authorize_actor(context, opts),
         {:ok, ticket_issue} <- fetch_ticket_issue(ticket_issue_id),
         {:ok, order} <- fetch_order(ticket_issue.sales_order_id),
         :ok <- authorize_event_scope(context, order.event_id),
         :ok <- validate_pending_source(ticket_issue, opts),
         :continue <- check_not_already_revoked(ticket_issue),
         {:ok, txn_result} <-
           revoke_in_transaction(ticket_issue, order, context, opts, sync_bump?: true) do
      maybe_invalidate_caches_post_commit(txn_result)

      if txn_result.status == :already_revoked do
        :telemetry.execute(
          TelemetryNames.ticket_revocation_idempotent(),
          %{},
          operational_metadata(context, ticket_issue_id: ticket_issue_id)
        )
      else
        emit_revocation_telemetry(txn_result, context)
      end

      {:ok,
       %{
         ticket_issue_id: txn_result.ticket_issue_id,
         attendee_id: txn_result.attendee_id,
         status: txn_result.status
       }}
    else
      {:ok, already_revoked_result} ->
        :telemetry.execute(
          TelemetryNames.ticket_revocation_idempotent(),
          %{},
          operational_metadata(context, ticket_issue_id: ticket_issue_id)
        )

        {:ok, already_revoked_result}

      {:error, _} = error ->
        :telemetry.execute(
          TelemetryNames.ticket_revocation_failed(),
          %{},
          operational_metadata(context, ticket_issue_id: ticket_issue_id)
        )

        error
    end
  end

  @doc """
  Revokes issued tickets for an order in a bounded batch.

  Mutates each ticket/attendee in one transaction, then bumps mobile sync version
  and invalidates caches once per event window. On partial failure, moves the order
  to `manual_review` without refund transitions.
  """
  @spec revoke_order_tickets(integer(), keyword()) ::
          {:ok, %{revoked: [revoke_result()], failures: [map()]}}
          | {:error, :not_found | :forbidden | :reason_required | :audit_context_required}
  def revoke_order_tickets(order_id, opts \\ []) when is_integer(order_id) do
    context = build_context(opts)

    with :ok <- authorize_actor(context, opts),
         {:ok, order} <- fetch_order(order_id),
         :ok <- authorize_event_scope(context, order.event_id),
         ticket_issues <- list_issued_ticket_issues(order_id),
         {:ok, batch_result} <-
           revoke_order_ticket_batch(order, ticket_issues, context, opts) do
      maybe_invalidate_caches_post_commit(batch_result)
      maybe_manual_review_order(order_id, batch_result.failures, context, opts)
      {:ok, %{revoked: batch_result.revoked, failures: batch_result.failures}}
    end
  end

  defp revoke_in_transaction(ticket_issue, order, context, opts, txn_opts) do
    reason = revocation_reason(opts)
    sync_bump? = Keyword.get(txn_opts, :sync_bump?, false)

    Repo.transaction(fn ->
      locked_issue = lock_ticket_issue!(ticket_issue.id)

      revoke_locked_ticket_issue(locked_issue, order, context, opts, reason,
        sync_bump?: sync_bump?
      )
    end)
    |> normalize_transaction_result()
  end

  defp revoke_order_ticket_batch(order, ticket_issues, context, opts) do
    initial = %{revoked: [], failures: [], cache_targets: []}

    result =
      Enum.reduce(ticket_issues, {:ok, initial}, fn ticket_issue, {:ok, acc} ->
        case revoke_in_transaction(ticket_issue, order, context, opts, sync_bump?: false) do
          {:ok, %{status: :revoked} = txn_result} ->
            target = %{
              event_id: order.event_id,
              ticket_code: txn_result.ticket_code,
              attendee_id: txn_result.attendee_id
            }

            {:ok,
             %{
               acc
               | revoked: acc.revoked ++ [format_revoke_result(txn_result)],
                 cache_targets: acc.cache_targets ++ [target]
             }}

          {:ok, txn_result} ->
            {:ok, %{acc | revoked: acc.revoked ++ [format_revoke_result(txn_result)]}}

          {:error, reason} ->
            failure = %{ticket_issue_id: ticket_issue.id, error: reason}
            {:ok, %{acc | failures: acc.failures ++ [failure]}}
        end
      end)

    with {:ok, acc} <- result,
         :ok <- bump_batch_sync_if_needed(order.event_id, acc.cache_targets) do
      {:ok,
       %{
         revoked: acc.revoked,
         failures: acc.failures,
         cache?: acc.cache_targets != [],
         event_id: order.event_id,
         cache_targets: acc.cache_targets
       }}
    end
  end

  defp bump_batch_sync_if_needed(_event_id, []), do: :ok

  defp bump_batch_sync_if_needed(event_id, cache_targets) do
    ticket_codes = Enum.map(cache_targets, & &1.ticket_code)
    attendee_ids = Enum.map(cache_targets, & &1.attendee_id)

    case MobileSyncVersionAggregator.after_attendees_created(
           event_id,
           ticket_codes,
           attendee_ids: attendee_ids,
           source: :sales_revocation,
           skip_cache_invalidation: true
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mobile_sync_version_aggregation_failed, reason}}
    end
  end

  defp revoke_locked_ticket_issue(
         %{status: "revoked"} = locked_issue,
         _order,
         _context,
         _opts,
         _reason,
         _txn_opts
       ) do
    %{
      ticket_issue_id: locked_issue.id,
      attendee_id: locked_issue.attendee_id,
      status: :already_revoked,
      cache?: false
    }
  end

  defp revoke_locked_ticket_issue(locked_issue, order, context, opts, reason, txn_opts) do
    sync_bump? = Keyword.get(txn_opts, :sync_bump?, false)

    with attendee when not is_nil(attendee) <- lock_and_validate_attendee!(locked_issue, order),
         {:ok, revoked_issue} <- mark_ticket_issue_revoked(locked_issue, reason, context, opts),
         {:ok, visibility} <-
           ScannerVisibility.mark_not_scannable(attendee, reason_code: ReasonCodes.revoked()),
         :ok <- maybe_emit_invalidation_telemetry(visibility, context, revoked_issue, order),
         :ok <- maybe_bump_sync_version(sync_bump?, order.event_id, visibility.attendee) do
      %{
        ticket_issue_id: revoked_issue.id,
        attendee_id: visibility.attendee.id,
        status: :revoked,
        cache?: sync_bump?,
        event_id: order.event_id,
        ticket_code: visibility.attendee.ticket_code
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_bump_sync_version(false, _event_id, _attendee), do: :ok

  defp maybe_bump_sync_version(true, event_id, attendee) do
    bump_invalidated_sync_version(event_id, attendee, ReasonCodes.revoked())
  end

  defp format_revoke_result(%{ticket_issue_id: id, attendee_id: attendee_id, status: status}) do
    %{ticket_issue_id: id, attendee_id: attendee_id, status: status}
  end

  defp maybe_emit_invalidation_telemetry(
         %{invalidation_appended: true},
         context,
         revoked_issue,
         order
       ) do
    :telemetry.execute(
      TelemetryNames.scanner_visibility_invalidation_appended(),
      %{},
      operational_metadata(context,
        ticket_issue_id: revoked_issue.id,
        attendee_id: revoked_issue.attendee_id,
        event_id: order.event_id
      )
    )

    :ok
  end

  defp maybe_emit_invalidation_telemetry(_visibility, _context, _revoked_issue, _order), do: :ok

  defp bump_invalidated_sync_version(event_id, attendee, reason_code) do
    case MobileSyncVersionAggregator.after_attendee_invalidated(
           event_id,
           attendee.id,
           attendee.ticket_code,
           reason_code,
           attendee_ids: [attendee.id],
           source: :sales_revocation,
           skip_cache_invalidation: true
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mobile_sync_version_aggregation_failed, reason}}
    end
  end

  defp maybe_invalidate_caches_post_commit(%{
         cache?: true,
         event_id: event_id,
         cache_targets: cache_targets
       })
       when is_list(cache_targets) and cache_targets != [] do
    ticket_codes = Enum.map(cache_targets, & &1.ticket_code)
    attendee_ids = Enum.map(cache_targets, & &1.attendee_id)

    _ =
      MobileSyncVersionAggregator.invalidate_attendees_created_caches(
        event_id,
        ticket_codes,
        attendee_ids: attendee_ids,
        source: :sales_revocation
      )

    :telemetry.execute(
      TelemetryNames.scanner_visibility_sync_queued(),
      %{},
      %{event_id: event_id, source: :sales_revocation}
    )

    :ok
  end

  defp maybe_invalidate_caches_post_commit(%{
         cache?: true,
         event_id: event_id,
         ticket_code: ticket_code,
         attendee_id: attendee_id
       }) do
    maybe_invalidate_caches_post_commit(%{
      cache?: true,
      event_id: event_id,
      cache_targets: [%{ticket_code: ticket_code, attendee_id: attendee_id}]
    })
  end

  defp maybe_invalidate_caches_post_commit(_result), do: :ok

  defp mark_ticket_issue_revoked(ticket_issue, reason, context, opts) do
    attrs = %{revocation_reason: reason}
    attrs = maybe_put_revoked_at(attrs, opts)

    ticket_issue
    |> Changeset.for_update(:mark_revoked, attrs,
      actor: context.actor,
      context: context
    )
    |> Ash.update(authorize?: false, return_notifications?: true)
    |> case do
      {:ok, record, notifications} ->
        Ash.Notifier.notify(notifications)
        {:ok, record}

      {:error, %Ash.Error.Invalid{errors: [%{field: :status} | _]}} ->
        {:error, :invalid_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_revoked_at(attrs, opts) do
    case Keyword.get(opts, :revoked_at) do
      %DateTime{} = revoked_at -> Map.put(attrs, :revoked_at, revoked_at)
      _ -> attrs
    end
  end

  defp maybe_manual_review_order(_order_id, [], _context, _opts), do: :ok

  defp maybe_manual_review_order(order_id, failures, context, _opts) when failures != [] do
    order = Ash.get!(Order, order_id, authorize?: false)

    _ =
      order
      |> Changeset.for_update(
        :mark_manual_review,
        %{manual_review_reason: "order_revocation_partial_failure"},
        actor: context.actor,
        context: context
      )
      |> Ash.update(authorize?: false)

    :ok
  end

  defp list_issued_ticket_issues(order_id) do
    TicketIssue
    |> AshQuery.for_read(:list_issued_by_order, %{sales_order_id: order_id})
    |> AshQuery.limit(@max_order_revoke_batch)
    |> Ash.read!(authorize?: false)
  end

  defp fetch_ticket_issue(ticket_issue_id) do
    case TicketIssue
         |> AshQuery.for_read(:get_by_id, %{id: ticket_issue_id})
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, ticket_issue} -> {:ok, ticket_issue}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_order(order_id) do
    case Ash.get(Order, order_id, authorize?: false) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, order} -> {:ok, order}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_not_already_revoked(%{status: "revoked"} = ticket_issue) do
    {:ok,
     %{
       ticket_issue_id: ticket_issue.id,
       attendee_id: ticket_issue.attendee_id,
       status: :already_revoked
     }}
  end

  defp check_not_already_revoked(_ticket_issue), do: :continue

  defp validate_pending_source(%{status: "pending"}, opts) do
    source = opts |> Keyword.get(:source, "") |> to_string()

    if source in @pending_revoke_sources do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp validate_pending_source(_ticket_issue, _opts), do: :ok

  defp lock_ticket_issue!(ticket_issue_id) do
    Repo.one!(
      from t in "sales_ticket_issues",
        where: t.id == ^ticket_issue_id,
        select: t.id,
        lock: "FOR UPDATE"
    )

    Ash.get!(TicketIssue, ticket_issue_id, authorize?: false)
  end

  defp lock_and_validate_attendee!(locked_issue, order) do
    case locked_issue.attendee_id do
      attendee_id when is_integer(attendee_id) ->
        attendee =
          Repo.one(
            from a in Attendee,
              where: a.id == ^attendee_id,
              lock: "FOR UPDATE"
          )

        cond do
          is_nil(attendee) ->
            Repo.rollback({:missing_attendee, locked_issue.id})

          attendee.ticket_code != locked_issue.ticket_code ->
            Repo.rollback({:conflict, :ticket_code_mismatch})

          attendee.event_id != order.event_id ->
            Repo.rollback({:conflict, :event_mismatch})

          true ->
            attendee
        end

      _ ->
        Repo.rollback({:missing_attendee, locked_issue.id})
    end
  end

  defp authorize_actor(context, opts) do
    actor_type = context.actor.actor_type

    cond do
      actor_type == :customer_session ->
        {:error, :forbidden}

      is_nil(actor_type) ->
        {:error, :forbidden}

      actor_type in [:admin, :operator] and blank_reason?(opts) ->
        {:error, :reason_required}

      actor_type in [:admin, :operator] and missing_allowed_event_ids?(context) ->
        {:error, :forbidden}

      actor_type == :system and blank_audit_context?(context) ->
        {:error, :audit_context_required}

      true ->
        :ok
    end
  end

  defp authorize_event_scope(context, event_id) do
    case context.actor.actor_type do
      :system ->
        :ok

      actor_type when actor_type in [:admin, :operator] ->
        allowed_event_ids = Map.get(context.actor, :allowed_event_ids, [])

        if is_integer(event_id) and event_id in allowed_event_ids do
          :ok
        else
          {:error, :forbidden}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  defp missing_allowed_event_ids?(context) do
    case Map.get(context.actor, :allowed_event_ids) do
      ids when is_list(ids) and ids != [] -> false
      _ -> true
    end
  end

  defp build_context(opts) do
    actor_type = Keyword.get(opts, :actor_type, :system)
    actor_id = Keyword.get(opts, :actor_id, "revocation")

    actor = %{
      actor_type: actor_type,
      actor_id: actor_id,
      correlation_id: Keyword.get(opts, :correlation_id),
      allowed_event_ids: Keyword.get(opts, :allowed_event_ids)
    }

    %{
      actor: actor,
      correlation_id: Keyword.get(opts, :correlation_id),
      idempotency_key: Keyword.get(opts, :idempotency_key)
    }
  end

  defp revocation_reason(opts) do
    case Keyword.get(opts, :reason) do
      reason when is_binary(reason) and reason != "" -> reason
      reason when is_atom(reason) -> Atom.to_string(reason)
      _ -> ReasonCodes.revoked()
    end
  end

  defp blank_reason?(opts) do
    case Keyword.fetch(opts, :reason) do
      :error -> true
      {:ok, reason} when is_binary(reason) -> String.trim(reason) == ""
      {:ok, reason} when is_atom(reason) -> false
      {:ok, _} -> true
    end
  end

  defp blank_audit_context?(context) do
    is_nil(context.correlation_id) and is_nil(context.idempotency_key)
  end

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}

  defp normalize_transaction_result({:error, {:mobile_sync_version_aggregation_failed, reason}}),
    do: {:error, {:mobile_sync_version_aggregation_failed, reason}}

  defp normalize_transaction_result({:error, {:missing_attendee, id}}),
    do: {:error, {:missing_attendee, id}}

  defp normalize_transaction_result({:error, {:conflict, reason}}),
    do: {:error, {:conflict, reason}}

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp emit_revocation_telemetry(%{status: :revoked}, context) do
    :telemetry.execute(TelemetryNames.ticket_revoked(), %{}, operational_metadata(context))
  end

  defp emit_revocation_telemetry(_result, _context), do: :ok

  defp operational_metadata(context, extra \\ []) do
    base = %{
      correlation_id: context.correlation_id,
      idempotency_key: context.idempotency_key,
      actor_type: context.actor.actor_type,
      actor_id: context.actor.actor_id
    }

    extra
    |> Enum.into(%{})
    |> Map.merge(base)
    |> Correlation.operational_metadata()
    |> Map.new()
    |> Redactor.safe_metadata()
  end
end
