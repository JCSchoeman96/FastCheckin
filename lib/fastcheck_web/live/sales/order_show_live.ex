defmodule FastCheckWeb.Sales.OrderShowLive do
  @moduledoc """
  Bounded dashboard order detail for Sales admin refund and revocation operations.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.{AdminRefunds, AdminRevocations}
  alias FastCheckWeb.Sales.Components.RevocationFormComponent

  @impl true
  def mount(%{"id" => order_id}, session, socket) do
    case AdminRefunds.get_order_operations_context(order_id) do
      {:ok, context} ->
        actor = actor_from_session(session, context.event_id)

        {:ok,
         socket
         |> assign(:page_title, "Sales order")
         |> assign(:actor, actor)
         |> assign(:context, context)
         |> assign(:action_error, nil)
         |> assign(:action_notice, nil)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Order not found")
         |> push_navigate(to: ~p"/dashboard/sales")}
    end
  end

  @impl true
  def handle_event("revoke_ticket", %{"admin_action" => params}, socket) do
    ticket_issue_id = Map.get(params, "ticket_issue_id")

    run_action(socket, fn ->
      AdminRevocations.revoke_ticket_issue(socket.assigns.actor, ticket_issue_id, params)
    end)
  end

  def handle_event("revoke_order_tickets", %{"admin_action" => params}, socket) do
    order_id = socket.assigns.context.sales_order_id

    run_action(socket, fn ->
      AdminRevocations.revoke_order_tickets(socket.assigns.actor, order_id, params)
    end)
  end

  def handle_event("mark_refunded", %{"admin_action" => params}, socket) do
    order_id = socket.assigns.context.sales_order_id

    run_action(socket, fn ->
      AdminRefunds.mark_order_refunded_manual(socket.assigns.actor, order_id, params)
    end)
  end

  def handle_event("mark_cancelled", %{"admin_action" => params}, socket) do
    order_id = socket.assigns.context.sales_order_id

    run_action(socket, fn ->
      AdminRefunds.mark_order_cancelled_manual(socket.assigns.actor, order_id, params)
    end)
  end

  def handle_event("hold_investigation", %{"admin_action" => params}, socket) do
    order_id = socket.assigns.context.sales_order_id

    run_action(socket, fn ->
      AdminRevocations.hold_for_refund_investigation(socket.assigns.actor, order_id, params)
    end)
  end

  def handle_event("close_no_refund", %{"admin_action" => params}, socket) do
    order_id = socket.assigns.context.sales_order_id

    run_action(socket, fn ->
      AdminRevocations.close_review_no_refund(socket.assigns.actor, order_id, params)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-5xl space-y-6 p-4">
        <div class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold text-fc-text-primary">Sales order operations</h1>
            <p class="text-sm text-fc-text-secondary">
              {@context.order_public_reference}
            </p>
          </div>
          <.link navigate={~p"/dashboard/sales"} class="text-sm text-fc-accent hover:underline">
            Back to dashboard
          </.link>
        </div>

        <p
          :if={@action_error}
          class="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
        >
          {@action_error}
        </p>
        <p
          :if={@action_notice}
          class="rounded border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-800"
        >
          {@action_notice}
        </p>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content class="space-y-2 text-sm">
            <h2 class="text-base font-semibold text-fc-text-primary">Order summary</h2>
            <dl class="grid gap-2 md:grid-cols-2">
              <div>
                <dt>Status</dt>
                <dd>{format_status(@context.current_status)}</dd>
              </div>
              <div>
                <dt>Buyer email</dt>
                <dd>{@context.buyer_email_masked}</dd>
              </div>
              <div>
                <dt>Buyer phone</dt>
                <dd>{@context.buyer_phone_masked}</dd>
              </div>
              <div>
                <dt>Issued tickets</dt>
                <dd>{@context.issued_ticket_count}</dd>
              </div>
              <div>
                <dt>Revoked tickets</dt>
                <dd>{@context.revoked_ticket_count}</dd>
              </div>
            </dl>
          </.card_content>
        </.card>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">Ticket issues</h2>
            <ul class="space-y-2 text-sm">
              <li
                :for={ticket <- @context.ticket_rows}
                class="flex items-center justify-between gap-2"
              >
                <span>Issue #{ticket.ticket_issue_id} · {ticket.ticket_code_suffix}</span>
                <span class="flex items-center gap-3">
                  <span>{format_status(ticket.status)} / {format_status(ticket.scanner_status)}</span>
                  <.link
                    :if={downloadable_ticket?(ticket)}
                    href={~p"/dashboard/sales/tickets/#{ticket.ticket_issue_id}/pdf"}
                    class="rounded border border-fc-border px-2 py-1 text-xs font-medium text-fc-accent hover:bg-fc-surface-raised"
                  >
                    Download PDF
                  </.link>
                </span>
              </li>
            </ul>
          </.card_content>
        </.card>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">Delivery attempts</h2>
            <p
              :if={Enum.empty?(@context.delivery_attempt_rows)}
              class="text-sm text-fc-text-secondary"
            >
              No delivery attempts recorded.
            </p>
            <ul class="space-y-2 text-sm">
              <li
                :for={attempt <- @context.delivery_attempt_rows}
                class="flex flex-col gap-1 border-t border-fc-border py-2 first:border-t-0 first:pt-0"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span>
                    {attempt.channel} / {attempt.provider} · {delivery_status(attempt.status)}
                  </span>
                  <span class="text-xs text-fc-text-muted">
                    {format_delivery_window(attempt.within_whatsapp_window)}
                  </span>
                </div>
                <div class="text-xs text-fc-text-muted">
                  Template {attempt.template_name || "none"} · Fallback {attempt.fallback_channel ||
                    "none"} · Reason {attempt.failure_reason || attempt.provider_error_code || "none"}
                </div>
              </li>
            </ul>
          </.card_content>
        </.card>

        <.card
          :if={@context.available_actions.can_revoke_ticket}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
        >
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">Revoke single ticket</h2>
            <RevocationFormComponent.revocation_form
              :for={ticket <- Enum.filter(@context.ticket_rows, &(&1.status == "issued"))}
              id={"revoke-ticket-#{ticket.ticket_issue_id}"}
              action="revoke_ticket"
              submit_label="Revoke ticket"
              ticket_issue_id={ticket.ticket_issue_id}
            />
          </.card_content>
        </.card>

        <.card
          :if={@context.available_actions.can_revoke_order_tickets}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
        >
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">
              Revoke all issued tickets
            </h2>
            <RevocationFormComponent.revocation_form
              id="revoke-order-tickets"
              action="revoke_order_tickets"
              submit_label="Revoke all issued tickets"
              show_bulk_confirmation
              show_password
              issued_count={@context.issued_ticket_count}
            />
          </.card_content>
        </.card>

        <.card
          :if={@context.available_actions.can_mark_refunded}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
        >
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">
              Mark order refunded (manual)
            </h2>
            <RevocationFormComponent.revocation_form
              id="mark-refunded"
              action="mark_refunded"
              submit_label="Mark refunded"
              show_password
            />
          </.card_content>
        </.card>

        <.card
          :if={@context.available_actions.can_mark_cancelled}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
        >
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">
              Mark order cancelled (manual)
            </h2>
            <RevocationFormComponent.revocation_form
              id="mark-cancelled"
              action="mark_cancelled"
              submit_label="Mark cancelled"
              show_password
            />
          </.card_content>
        </.card>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <h2 class="mb-2 text-base font-semibold text-fc-text-primary">
              State transition timeline
            </h2>
            <ul class="space-y-2 text-sm">
              <li :for={entry <- @context.timeline}>
                {timeline_label(entry)} · {format_datetime(entry.inserted_at)}
              </li>
            </ul>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp run_action(socket, fun) do
    case fun.() do
      {:ok, _result} ->
        order_id = socket.assigns.context.sales_order_id

        case AdminRefunds.get_order_operations_context(order_id) do
          {:ok, context} ->
            {:noreply,
             socket
             |> assign(:context, context)
             |> assign(:action_error, nil)
             |> assign(:action_notice, "Action completed successfully.")}

          {:error, _} ->
            {:noreply,
             assign(socket, :action_error, "Action completed but order could not be reloaded.")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:action_notice, nil)
         |> assign(:action_error, format_error(reason))}
    end
  end

  defp actor_from_session(session, event_id) do
    username = session["dashboard_username"] || "dashboard"

    %{
      id: username,
      username: username,
      actor_type: :admin,
      allowed_event_ids: [event_id]
    }
  end

  defp format_status(nil), do: "None"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp downloadable_ticket?(ticket) do
    ticket.status == "issued" and ticket.scanner_status == "valid"
  end

  defp delivery_status(nil), do: "none"
  defp delivery_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp format_delivery_window(true), do: "inside window"
  defp format_delivery_window(false), do: "outside window"
  defp format_delivery_window(_), do: "window unknown"

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  defp format_datetime(other), do: to_string(other)

  defp timeline_label(%{kind: "state_transition", action: action}), do: action
  defp timeline_label(%{kind: "manual_review_action", action: action}), do: action
  defp timeline_label(_), do: "event"

  defp format_error({:revoke_failures, failures}),
    do: "Could not revoke #{length(failures)} ticket(s). Order was not marked refunded/cancelled."

  defp format_error(:reason_required), do: "Reason is required."
  defp format_error(:bulk_confirmation_required), do: "Bulk confirmation is required."
  defp format_error(:invalid_admin_password), do: "Incorrect admin password."
  defp format_error(:verified_payment_required), do: "Verified payment context is required."
  defp format_error(:forbidden), do: "You are not allowed to perform this action."

  defp format_error({:mobile_sync_version_aggregation_failed, _}),
    do: "Mobile sync update failed. Please retry."

  defp format_error(reason) when is_atom(reason), do: format_error(to_string(reason))
  defp format_error(reason), do: to_string(reason)
end
