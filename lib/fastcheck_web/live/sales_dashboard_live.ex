defmodule FastCheckWeb.SalesDashboardLive do
  @moduledoc """
  Read-only Admin Sales Dashboard.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.AdminDashboard

  @impl true
  def mount(_params, _session, socket) do
    filters = %{}

    {:ok,
     socket
     |> assign(:page_title, "Sales dashboard")
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:selected_order_id, nil)
     |> assign(:selected_order_detail, nil)
     |> assign(:detail_error, nil)
     |> load_dashboard(filters)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = allowed_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:selected_order_id, nil)
     |> assign(:selected_order_detail, nil)
     |> assign(:detail_error, nil)
     |> load_dashboard(filters)}
  end

  def handle_event("select_order", %{"order-id" => order_id}, socket) do
    case AdminDashboard.order_detail(order_id) do
      {:ok, detail} ->
        {:noreply,
         socket
         |> assign(:selected_order_id, detail.id)
         |> assign(:selected_order_detail, detail)
         |> assign(:detail_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:selected_order_id, nil)
         |> assign(:selected_order_detail, nil)
         |> assign(:detail_error, "Order not found")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_dashboard(socket, filters) do
    socket
    |> assign(:summary, AdminDashboard.summary(filters))
    |> assign(:recent_orders, AdminDashboard.recent_orders(filters))
    |> assign(:manual_review_queue, AdminDashboard.manual_review_queue(filters))
    |> assign(:inventory_summary, AdminDashboard.inventory_summary(filters))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Sales dashboard">
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold text-fc-text-primary">Sales dashboard</h1>
          <p class="text-sm text-fc-text-secondary">
            Read-only Sales health, payment, ticket, review, and inventory status.
          </p>
        </header>

        <.form
          for={@form}
          id="sales-dashboard-filters"
          phx-submit="apply_filters"
          class="grid gap-3 rounded-lg border border-fc-border bg-white/70 p-4 md:grid-cols-4"
        >
          <.input field={@form[:event_id]} type="number" label="Event ID" />
          <.input field={@form[:search]} type="text" label="Order reference" />
          <.input
            field={@form[:status]}
            type="select"
            label="Order status"
            prompt="Any"
            options={status_options()}
          />
          <.input
            field={@form[:source_channel]}
            type="select"
            label="Channel"
            prompt="Any"
            options={channel_options()}
          />
          <.input
            field={@form[:payment_status]}
            type="select"
            label="Payment status"
            prompt="Any"
            options={payment_status_options()}
          />
          <.input field={@form[:from_date]} type="date" label="From" />
          <.input field={@form[:to_date]} type="date" label="To" />
          <div class="flex items-end">
            <.button type="submit" variant="solid" color="primary">Apply filters</.button>
          </div>
        </.form>

        <section class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
          <.metric label="Orders" value={@summary.orders_in_window} />
          <.metric label="Paid verified" value={@summary.paid_verified} />
          <.metric label="Issued" value={@summary.issued} />
          <.metric label="Failed or mismatch" value={@summary.failed_mismatch} />
          <.metric label="Manual review" value={@summary.manual_review_open} />
          <.metric label="Expired checkout" value={@summary.expired_checkout} />
        </section>

        <section class="grid gap-6 xl:grid-cols-[1.4fr_1fr]">
          <.card variant="outline" color="natural" rounded="large" padding="large">
            <.card_content>
              <h2 class="text-lg font-semibold text-fc-text-primary">Recent orders</h2>
              <div class="mt-4 overflow-x-auto">
                <table class="min-w-full text-left text-sm">
                  <thead class="text-xs uppercase text-fc-text-muted">
                    <tr>
                      <th class="py-2 pr-4">Reference</th>
                      <th class="py-2 pr-4">Status</th>
                      <th class="py-2 pr-4">Payment</th>
                      <th class="py-2 pr-4">Tickets</th>
                      <th class="py-2 pr-4">Buyer</th>
                      <th class="py-2 pr-4">Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :if={Enum.empty?(@recent_orders)}>
                      <td colspan="6" class="py-6 text-fc-text-secondary">No recent orders.</td>
                    </tr>
                    <tr :for={order <- @recent_orders} class="border-t border-fc-border">
                      <td class="py-3 pr-4 font-medium text-fc-text-primary">
                        {order.order_public_reference}
                      </td>
                      <td class="py-3 pr-4">{format_status(order.order_status)}</td>
                      <td class="py-3 pr-4">{format_status(order.payment_status_summary)}</td>
                      <td class="py-3 pr-4">
                        {order.issued_ticket_count}/{order.expected_ticket_count}
                      </td>
                      <td class="py-3 pr-4">
                        <div>{order.buyer_display_name}</div>
                        <div class="text-xs text-fc-text-muted">{order.buyer_email_masked}</div>
                        <div class="text-xs text-fc-text-muted">{order.buyer_phone_masked}</div>
                      </td>
                      <td class="py-3 pr-4">
                        <.button
                          type="button"
                          variant="ghost"
                          color="primary"
                          phx-click="select_order"
                          phx-value-order-id={order.id}
                        >
                          Open detail
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </.card_content>
          </.card>

          <.card variant="outline" color="warning" rounded="large" padding="large">
            <.card_content>
              <h2 class="text-lg font-semibold text-fc-text-primary">Manual review</h2>
              <div class="mt-4 space-y-3">
                <p :if={Enum.empty?(@manual_review_queue)} class="text-sm text-fc-text-secondary">
                  No manual review cases in the current window.
                </p>
                <div
                  :for={review <- @manual_review_queue}
                  class="rounded-md border border-fc-border p-3 text-sm"
                >
                  <div class="flex items-center justify-between gap-3">
                    <p class="font-medium text-fc-text-primary">{review.order_public_reference}</p>
                    <.button
                      type="button"
                      variant="ghost"
                      color="primary"
                      phx-click="select_order"
                      phx-value-order-id={review.id}
                    >
                      Open detail
                    </.button>
                  </div>
                  <p class="mt-1 text-fc-text-secondary">{review.reason_code}</p>
                  <p class="mt-1 text-xs text-fc-text-muted">{review.recommended_action}</p>
                </div>
              </div>
            </.card_content>
          </.card>
        </section>

        <section class="grid gap-6 xl:grid-cols-[1fr_1fr]">
          <.card variant="outline" color="natural" rounded="large" padding="large">
            <.card_content>
              <h2 class="text-lg font-semibold text-fc-text-primary">Inventory health</h2>
              <div class="mt-4 space-y-3">
                <p :if={Enum.empty?(@inventory_summary)} class="text-sm text-fc-text-secondary">
                  No visible ticket offers.
                </p>
                <div
                  :for={offer <- @inventory_summary}
                  class="grid gap-1 rounded-md border border-fc-border p-3 text-sm"
                >
                  <p class="font-medium text-fc-text-primary">{offer.name}</p>
                  <p class="text-fc-text-secondary">
                    Status: {format_status(offer.inventory_status)}
                  </p>
                  <p class="text-xs text-fc-text-muted">
                    Sold {offer.sold_count || 0} · Holds {offer.active_hold_count || 0} · Redis available {offer.redis_available ||
                      "unknown"}
                  </p>
                </div>
              </div>
            </.card_content>
          </.card>

          <.card variant="outline" color="natural" rounded="large" padding="large">
            <.card_content>
              <h2 class="text-lg font-semibold text-fc-text-primary">Order detail</h2>
              <p :if={@detail_error} class="mt-4 text-sm text-fc-text-secondary">{@detail_error}</p>
              <p
                :if={is_nil(@selected_order_detail) and is_nil(@detail_error)}
                class="mt-4 text-sm text-fc-text-secondary"
              >
                Select an order to inspect its safe summary.
              </p>
              <div :if={@selected_order_detail} class="mt-4 space-y-3 text-sm">
                <p class="text-base font-semibold text-fc-text-primary">
                  {@selected_order_detail.order_public_reference}
                </p>
                <dl class="grid gap-2 md:grid-cols-2">
                  <div>
                    <dt>Status</dt>
                    <dd>{format_status(@selected_order_detail.order_status)}</dd>
                  </div>
                  <div>
                    <dt>Payment</dt>
                    <dd>{format_status(@selected_order_detail.payment_status_summary)}</dd>
                  </div>
                  <div>
                    <dt>Checkout</dt>
                    <dd>{format_status(@selected_order_detail.checkout_status)}</dd>
                  </div>
                  <div>
                    <dt>Ticket issues</dt>
                    <dd>{@selected_order_detail.ticket_issue_count}</dd>
                  </div>
                  <div>
                    <dt>Issued tickets</dt>
                    <dd>{@selected_order_detail.issued_ticket_count}</dd>
                  </div>
                  <div>
                    <dt>Attendee links</dt>
                    <dd>{@selected_order_detail.attendee_link_count}</dd>
                  </div>
                </dl>
              </div>
            </.card_content>
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metric(assigns) do
    ~H"""
    <div class="rounded-lg border border-fc-border bg-white/70 p-4">
      <p class="text-xs uppercase tracking-wide text-fc-text-muted">{@label}</p>
      <p class="mt-2 text-2xl font-semibold text-fc-text-primary">{@value}</p>
    </div>
    """
  end

  defp allowed_filters(params) when is_map(params) do
    Map.take(params, ~w(event_id search status source_channel payment_status from_date to_date))
  end

  defp status_options do
    ~w(awaiting_payment payment_pending paid_unverified paid_verified fulfillment_queued ticket_issued partially_issued manual_review expired)
    |> Enum.map(&{format_status(&1), &1})
  end

  defp channel_options,
    do: Enum.map(~w(admin internal_pilot whatsapp web system test), &{format_status(&1), &1})

  defp payment_status_options do
    ~w(initialized authorization_url_sent verified_success verified_amount_mismatch verified_currency_mismatch failed duplicate manual_review)
    |> Enum.map(&{format_status(&1), &1})
  end

  defp format_status(nil), do: "None"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
