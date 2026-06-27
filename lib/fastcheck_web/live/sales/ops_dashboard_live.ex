defmodule FastCheckWeb.Sales.OpsDashboardLive do
  @moduledoc """
  Read-only Sales operations dashboard.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.OpsMetrics

  @impl true
  def mount(_params, _session, socket) do
    filters = %{"window" => "1h"}

    {:ok,
     socket
     |> assign(:page_title, "Sales operations")
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> load_dashboard(filters)}
  end

  @impl true
  def handle_event("apply_filters", %{"filters" => params}, socket) do
    filters = Map.take(params, ~w(event_id source_channel window))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> load_dashboard(filters)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_dashboard(socket, filters) do
    socket
    |> assign(:summary, OpsMetrics.summary(filters))
    |> assign(:recent_failures, OpsMetrics.recent_failures(filters))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Sales operations">
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold text-fc-text-primary">Sales operations</h1>
          <p class="text-sm text-fc-text-secondary">
            Read-only Sales health, payment, ticket, delivery, review, and worker backlog.
          </p>
        </header>

        <.form
          for={@form}
          id="sales-ops-filters"
          phx-submit="apply_filters"
          class="grid gap-3 rounded-lg border border-fc-border bg-white/70 p-4 md:grid-cols-4"
        >
          <.input field={@form[:event_id]} type="number" label="Event ID" />
          <.input
            field={@form[:source_channel]}
            type="select"
            label="Channel"
            prompt="Any"
            options={channel_options()}
          />
          <.input
            field={@form[:window]}
            type="select"
            label="Window"
            options={[{"15 minutes", "15m"}, {"1 hour", "1h"}, {"24 hours", "24h"}, {"7 days", "7d"}]}
          />
          <div class="flex items-end">
            <.button type="submit" variant="solid" color="primary">Apply filters</.button>
          </div>
        </.form>

        <section class="grid gap-4 md:grid-cols-3 xl:grid-cols-6">
          <.metric label="Manual review" value={@summary.manual_review_open_count} />
          <.metric label="Payment mismatch" value={@summary.payment_mismatch_count} />
          <.metric label="Unmatched webhooks" value={@summary.payment_unmatched_event_count} />
          <.metric label="Revoked tickets" value={@summary.tickets_revoked_count} />
          <.metric label="Delivery fallback" value={@summary.delivery_fallback_required_count} />
          <.metric label="Scanner visibility" value={@summary.scanner_visibility_pending_count} />
        </section>

        <section class="grid gap-6 xl:grid-cols-2">
          <.panel title="Payment health" rows={@summary.payment_attempts_by_status} />
          <.panel title="Ticket health" rows={ticket_rows(@summary)} />
          <.panel title="Delivery health" rows={@summary.delivery_attempts_by_status} />
          <.panel title="Worker backlog" rows={@summary.worker_retry_backlog_by_queue} />
        </section>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <div class="flex items-center justify-between gap-4">
              <h2 class="text-lg font-semibold text-fc-text-primary">Recent failures</h2>
              <.link
                navigate={~p"/dashboard/sales/reviews"}
                class="text-sm text-fc-accent hover:underline"
              >
                Open manual review
              </.link>
            </div>
            <div class="mt-4 overflow-x-auto">
              <table class="min-w-full text-left text-sm">
                <thead class="text-xs uppercase text-fc-text-muted">
                  <tr>
                    <th class="py-2 pr-4">Kind</th>
                    <th class="py-2 pr-4">Reference</th>
                    <th class="py-2 pr-4">Status</th>
                    <th class="py-2 pr-4">Reason</th>
                    <th class="py-2 pr-4">Audit</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :if={Enum.empty?(@recent_failures)}>
                    <td colspan="5" class="py-6 text-fc-text-secondary">No recent failures.</td>
                  </tr>
                  <tr :for={failure <- @recent_failures} class="border-t border-fc-border">
                    <td class="py-3 pr-4">{format_status(failure.kind)}</td>
                    <td class="py-3 pr-4 font-medium text-fc-text-primary">
                      {failure.order_public_reference}
                    </td>
                    <td class="py-3 pr-4">{format_status(failure.status)}</td>
                    <td class="py-3 pr-4">{failure.reason_code || "none"}</td>
                    <td class="py-3 pr-4">
                      <.link
                        navigate={~p"/dashboard/sales/audit/payment_attempt/#{failure.id}"}
                        class="text-fc-accent hover:underline"
                      >
                        Timeline
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.card_content>
        </.card>
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
      <p class="mt-2 text-2xl font-semibold text-fc-text-primary">{@value || 0}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :map, required: true

  defp panel(assigns) do
    ~H"""
    <.card variant="outline" color="natural" rounded="large" padding="large">
      <.card_content>
        <h2 class="text-lg font-semibold text-fc-text-primary">{@title}</h2>
        <div class="mt-4 space-y-2 text-sm">
          <p :if={map_size(@rows) == 0} class="text-fc-text-secondary">No rows.</p>
          <div :for={{label, value} <- Enum.sort(@rows)} class="flex justify-between gap-4">
            <span>{format_status(label)}</span>
            <span class="font-semibold text-fc-text-primary">{value}</span>
          </div>
        </div>
      </.card_content>
    </.card>
    """
  end

  defp ticket_rows(summary) do
    %{
      "issued" => summary.tickets_issued_count,
      "partially_issued" => summary.tickets_partially_issued_count,
      "manual_review" => summary.ticket_issue_failure_count,
      "revoked" => summary.tickets_revoked_count
    }
  end

  defp channel_options,
    do: Enum.map(~w(admin internal_pilot whatsapp web system test), &{format_status(&1), &1})

  defp format_status(nil), do: "None"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
