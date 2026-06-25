defmodule FastCheck.Sales.AdminRevocations do
  @moduledoc """
  Dashboard admin orchestration for Sales ticket revocation.

  LiveViews must call this module instead of invoking `FastCheck.Tickets.Revocation`
  directly. Scanner-visible revocation remains owned by VS-15A `Revocation`.
  """

  import Ecto.Query

  alias FastCheck.Observability.{Correlation, Redactor, TelemetryNames}
  alias FastCheck.Repo
  alias FastCheck.Sales.ManualReview
  alias FastCheck.Sales.Order
  alias FastCheck.Tickets.Revocation
  alias FastCheckWeb.Plugs.BrowserAuth

  @admin_source "admin_sales_dashboard"

  @doc "Revokes a single issued ticket issue through the VS-15A core path."
  def revoke_ticket_issue(actor, ticket_issue_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, ticket_issue_id} <- parse_integer(ticket_issue_id) do
      do_revoke_ticket_issue(actor, ticket_issue_id, attrs)
    end
  end

  defp do_revoke_ticket_issue(actor, ticket_issue_id, attrs) do
    :telemetry.execute(
      TelemetryNames.admin_revocation_requested(),
      %{},
      telemetry_metadata(actor, ticket_issue_id: ticket_issue_id, action: "revoke_ticket_issue")
    )

    with :ok <- require_reason(attrs),
         {:ok, order} <- load_order_for_ticket_issue(ticket_issue_id),
         :ok <- authorize_dashboard_actor(actor, order.event_id),
         :ok <- maybe_require_admin_password(attrs, required?: false),
         opts = revocation_opts(actor, order.event_id, attrs),
         {:ok, result} <- Revocation.revoke_ticket_issue(ticket_issue_id, opts) do
      :telemetry.execute(
        TelemetryNames.admin_revocation_completed(),
        %{},
        telemetry_metadata(actor,
          ticket_issue_id: ticket_issue_id,
          action: "revoke_ticket_issue",
          status: result.status
        )
      )

      {:ok, result}
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, ticket_issue_id: ticket_issue_id, action: "revoke_ticket_issue")
        error

      {:error, _} = error ->
        :telemetry.execute(
          TelemetryNames.admin_revocation_failed(),
          %{},
          telemetry_metadata(actor,
            ticket_issue_id: ticket_issue_id,
            action: "revoke_ticket_issue"
          )
        )

        error
    end
  end

  @doc "Revokes all issued tickets for an order in a bounded batch."
  def revoke_order_tickets(actor, order_id, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    :telemetry.execute(
      TelemetryNames.admin_revocation_requested(),
      %{},
      telemetry_metadata(actor, order_id: order_id, action: "revoke_order_tickets")
    )

    with :ok <- require_reason(attrs),
         :ok <- require_bulk_confirmation(attrs),
         :ok <- maybe_require_admin_password(attrs, required?: true),
         {:ok, order} <- load_order(order_id),
         :ok <- require_admin_actor(actor),
         :ok <- authorize_dashboard_actor(actor, order.event_id),
         opts = revocation_opts(actor, order.event_id, attrs),
         {:ok, result} <- invoke_order_ticket_revocation(order_id, opts) do
      case Map.get(result, :failures, []) do
        [_ | _] = failures ->
          :telemetry.execute(
            TelemetryNames.admin_revocation_failed(),
            %{},
            telemetry_metadata(actor, order_id: order_id, action: "revoke_order_tickets")
          )

          {:error, {:revoke_failures, failures}}

        [] ->
          :telemetry.execute(
            TelemetryNames.admin_revocation_completed(),
            %{},
            telemetry_metadata(actor, order_id: order_id, action: "revoke_order_tickets")
          )

          {:ok, result}
      end
    else
      {:error, :forbidden} = error ->
        emit_denied(actor, order_id: order_id, action: "revoke_order_tickets")
        error

      {:error, _} = error ->
        :telemetry.execute(
          TelemetryNames.admin_revocation_failed(),
          %{},
          telemetry_metadata(actor, order_id: order_id, action: "revoke_order_tickets")
        )

        error
    end
  end

  @doc "Delegates hold-for-investigation to the VS-13 manual review boundary."
  def hold_for_refund_investigation(actor, order_id, attrs) do
    attrs = Map.put(stringify_keys(attrs), "reason_code", "hold_for_investigation")
    ManualReview.hold_for_investigation(order_id, actor, attrs)
  end

  @doc "Delegates close-without-refund to the VS-13 manual review boundary."
  def close_review_no_refund(actor, order_id, attrs) do
    attrs =
      stringify_keys(attrs)
      |> Map.put("reason_code", "close_no_fulfillment")

    ManualReview.close_no_fulfillment(order_id, actor, attrs)
  end

  defp invoke_order_ticket_revocation(order_id, opts) do
    case Revocation.revoke_order_tickets(order_id, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:mobile_sync_version_aggregation_failed, _} = error} ->
        {:error, error}

      {:error, {:missing_attendee, ticket_issue_id}} ->
        {:ok,
         %{
           revoked: [],
           failures: [
             %{ticket_issue_id: ticket_issue_id, error: {:missing_attendee, ticket_issue_id}}
           ]
         }}

      {:error, :rollback} ->
        {:ok,
         %{
           revoked: [],
           failures: failures_for_still_issued_tickets(order_id, :rollback)
         }}

      {:error, reason} ->
        {:ok, %{revoked: [], failures: [%{error: reason}]}}
    end
  end

  defp failures_for_still_issued_tickets(order_id, error_reason) do
    order_id
    |> issued_ticket_issue_ids()
    |> Enum.map(&%{ticket_issue_id: &1, error: error_reason})
  end

  defp issued_ticket_issue_ids(order_id) do
    Repo.all(
      from t in "sales_ticket_issues",
        where: t.sales_order_id == ^order_id and t.status == "issued",
        order_by: [asc: t.id],
        select: t.id
    )
  end

  defp require_reason(attrs) do
    reason = blank_to_nil(Map.get(attrs, "reason"))

    if is_binary(reason) and reason != "" do
      :ok
    else
      {:error, :reason_required}
    end
  end

  defp require_bulk_confirmation(attrs) do
    if truthy?(Map.get(attrs, "confirmed_bulk")) do
      :ok
    else
      {:error, :bulk_confirmation_required}
    end
  end

  defp maybe_require_admin_password(attrs, opts) do
    required? = Keyword.get(opts, :required?, false)
    password = Map.get(attrs, "admin_password")

    cond do
      not required? ->
        :ok

      BrowserAuth.valid_admin_password?(password) ->
        :ok

      true ->
        {:error, :invalid_admin_password}
    end
  end

  defp require_admin_actor(actor) do
    if actor_type(actor) == :admin, do: :ok, else: {:error, :forbidden}
  end

  defp authorize_dashboard_actor(actor, event_id) do
    case actor_type(actor) do
      type when type in [:admin, :operator] ->
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

  defp revocation_opts(actor, _event_id, attrs) do
    [
      actor_type: actor_type(actor),
      actor_id: actor_id(actor),
      reason: Map.get(attrs, "reason"),
      allowed_event_ids: allowed_event_ids(actor),
      correlation_id: Map.get(attrs, "correlation_id") || Correlation.ensure_correlation_id(%{}),
      idempotency_key: Map.get(attrs, "idempotency_key"),
      source: @admin_source
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> maybe_put_test_aggregator(attrs)
  end

  defp maybe_put_test_aggregator(opts, attrs) do
    case Map.get(attrs, "mobile_sync_version_aggregator") do
      nil -> opts
      aggregator -> Keyword.put(opts, :mobile_sync_version_aggregator, aggregator)
    end
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

  defp load_order_for_ticket_issue(ticket_issue_id) do
    with {:ok, id} <- parse_integer(ticket_issue_id),
         row <-
           Repo.one(
             from t in "sales_ticket_issues",
               where: t.id == ^id,
               select: %{sales_order_id: t.sales_order_id}
           ),
         nil <- row do
      {:error, :not_found}
    else
      %{sales_order_id: order_id} -> load_order(order_id)
      {:error, _} = error -> error
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

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp emit_denied(actor, metadata) do
    :telemetry.execute(
      TelemetryNames.admin_action_denied(),
      %{},
      telemetry_metadata(actor, metadata)
    )
  end

  defp telemetry_metadata(actor, extra) do
    extra_map = if is_list(extra), do: Map.new(extra), else: extra

    Correlation.operational_metadata(
      Map.merge(
        %{
          actor_type: actor_type(actor),
          actor_id: actor_id(actor),
          source: @admin_source
        },
        extra_map
      )
    )
    |> Redactor.safe_metadata()
  end
end
