defmodule FastCheck.Sales.AdminRefunds do
  @moduledoc """
  Dashboard admin orchestration for manual order refund/cancel markers.

  Revokes issued tickets through `AdminRevocations` before transitioning order
  state. Does not call Paystack or mutate scanner state directly.
  """

  import Ecto.Query

  alias Ash.Changeset
  alias FastCheck.Observability.{Correlation, Redactor, TelemetryNames}
  alias FastCheck.Repo
  alias FastCheck.Sales.{AdminRevocations, ManualReview, Order}
  alias FastCheckWeb.Plugs.BrowserAuth

  @admin_source "admin_sales_dashboard"
  @default_limit 25
  @max_limit 25
  @post_payment_order_statuses ~w(
    paid_verified fulfillment_queued ticket_issued partially_issued
    manual_review manual_review_held issuance_retry_queued refunded cancelled
  )

  @doc "Returns bounded, masked order context for admin refund/revoke operations."
  def get_order_operations_context(order_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp(1, @max_limit)

    with {:ok, order} <- load_order(order_id),
         {:ok, base} <- ManualReview.get_context("order", order.id) do
      ticket_counts = ticket_status_counts(order.id)
      tickets = bounded_ticket_summaries(order.id, limit)

      timeline =
        base
        |> Map.get(:timeline, [])
        |> Enum.take(limit)

      {:ok,
       base
       |> Map.put(:timeline, timeline)
       |> Map.put(:ticket_rows, tickets)
       |> Map.put(:issued_ticket_count, ticket_counts.issued)
       |> Map.put(:revoked_ticket_count, ticket_counts.revoked)
       |> Map.put(:available_actions, available_actions(order, ticket_counts))}
    end
  end

  @doc "Marks an order manually refunded after revoking all issued tickets."
  def mark_order_refunded_manual(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- require_admin_actor(actor),
         :ok <- require_reason(attrs),
         :ok <- maybe_require_admin_password(attrs),
         {:ok, order} <- load_order(order_id),
         :ok <- authorize_event(actor, order.event_id),
         :ok <- verified_payment_context?(order),
         {:ok, revoke_result} <- revoke_issued_tickets(actor, order, attrs) do
      case Map.get(revoke_result, :failures, Map.get(revoke_result, "failures", [])) do
        [_ | _] = failures ->
          maybe_move_to_manual_review(order_id, actor, attrs, failures)
          {:error, {:revoke_failures, failures}}

        [] ->
          case transition_refunded(order, actor, attrs) do
            {:ok, updated} ->
              emit_refund_marked(actor, order.id)
              {:ok, %{order: updated, revoke: revoke_result}}

            {:error, _} = error ->
              error
          end
      end
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, order_id, "mark_order_refunded_manual")
        error

      {:error, _} = error ->
        error
    end
  end

  @doc "Marks an order manually cancelled after revoking issued tickets when present."
  def mark_order_cancelled_manual(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with :ok <- require_admin_actor(actor),
         :ok <- require_reason(attrs),
         :ok <- maybe_require_admin_password(attrs),
         {:ok, order} <- load_order(order_id),
         :ok <- authorize_event(actor, order.event_id),
         {:ok, revoke_result} <- revoke_issued_tickets(actor, order, attrs) do
      case Map.get(revoke_result, :failures, Map.get(revoke_result, "failures", [])) do
        [_ | _] = failures ->
          maybe_move_to_manual_review(order_id, actor, attrs, failures)
          {:error, {:revoke_failures, failures}}

        [] ->
          case transition_cancelled(order, actor, attrs) do
            {:ok, updated} -> {:ok, %{order: updated, revoke: revoke_result}}
            {:error, _} = error -> error
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

  defp verified_payment_context?(%{status: status}) when status in @post_payment_order_statuses,
    do: :ok

  defp verified_payment_context?(order) do
    case latest_payment_status(order.id) do
      "verified_success" -> :ok
      _ -> {:error, :verified_payment_required}
    end
  end

  defp revoke_issued_tickets(actor, order, attrs) do
    counts = ticket_status_counts(order.id)

    if counts.issued == 0 do
      {:ok, %{revoked: [], failures: []}}
    else
      revoke_attrs =
        attrs
        |> Map.put("confirmed_bulk", "true")
        |> Map.put("admin_password", Map.get(attrs, "admin_password"))

      case AdminRevocations.revoke_order_tickets(actor, order.id, revoke_attrs) do
        {:error, {:revoke_failures, failures}} ->
          {:ok, %{revoked: [], failures: failures}}

        other ->
          other
      end
    end
  end

  defp transition_refunded(order, actor, attrs) do
    if order.status == "refunded" do
      {:ok, order}
    else
      order
      |> Changeset.for_update(
        :mark_refunded_manual,
        %{reason: Map.get(attrs, "reason")},
        actor: ash_actor(actor, order.event_id, attrs)
      )
      |> Ash.update(authorize?: false)
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

  defp maybe_move_to_manual_review(order_id, actor, attrs, failures) do
    reason =
      "Revoke failures during admin refund: #{length(failures)} ticket(s) could not be revoked"

    _ =
      order_id
      |> load_order()
      |> case do
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

  defp available_actions(order, counts) do
    %{
      can_revoke_ticket: counts.issued > 0,
      can_revoke_order_tickets: counts.issued > 0,
      can_mark_refunded: order.status != "refunded",
      can_mark_cancelled: order.status not in ["cancelled", "refunded"],
      can_hold_investigation: order.status in ["manual_review", "manual_review_held"],
      can_close_no_refund: order.status in ["manual_review", "manual_review_held"]
    }
  end

  defp latest_payment_status(order_id) do
    Repo.one(
      from p in "sales_payment_attempts",
        where: p.sales_order_id == ^order_id,
        order_by: [desc: p.inserted_at, desc: p.id],
        limit: 1,
        select: p.status
    )
  end

  defp require_admin_actor(actor) do
    if actor_type(actor) == :admin, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_event(actor, event_id) do
    case actor_type(actor) do
      :admin ->
        cond do
          not is_integer(event_id) ->
            {:error, :forbidden}

          event_allowed?(actor, event_id) ->
            :ok

          true ->
            {:error, :forbidden}
        end

      _ ->
        {:error, :forbidden}
    end
  end

  defp event_allowed?(actor, event_id) do
    case allowed_event_ids(actor) do
      ids when is_list(ids) and ids != [] -> event_id in ids
      _ -> false
    end
  end

  defp allowed_event_ids(actor) do
    Map.get(actor, :allowed_event_ids) || Map.get(actor, "allowed_event_ids")
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
    %{
      actor_type: actor_type(actor),
      actor_id: actor_id(actor),
      allowed_event_ids: allowed_event_ids(actor),
      correlation_id: Map.get(attrs, "correlation_id"),
      idempotency_key: Map.get(attrs, "idempotency_key")
    }
  end

  defp load_order(order_id) do
    with {:ok, id} <- parse_integer(order_id) do
      Order
      |> Ash.Query.for_read(:get_by_id, %{id: id})
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} -> {:error, :not_found}
        {:ok, order} -> {:ok, order}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp actor_type(actor) do
    Map.get(actor, :actor_type) || Map.get(actor, "actor_type") || :admin
  end

  defp actor_id(actor) do
    Map.get(actor, :id) || Map.get(actor, "id") || Map.get(actor, :username) ||
      Map.get(actor, "username") || "dashboard"
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
