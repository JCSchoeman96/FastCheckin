defmodule FastCheckWeb.Sales.EventOverviewLive do
  @moduledoc """
  Read-only per-event admin overview across WordPress/Tickera attendees and
  WhatsApp/FastCheck Sales activity.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.AdminDashboard

  @impl true
  def mount(%{"event_id" => event_id_param}, _session, socket) do
    case AdminDashboard.event_overview(event_id_param) do
      {:ok, overview} ->
        event = overview.event

        {:ok,
         socket
         |> assign(:page_title, "Event overview")
         |> assign(:overview, overview)
         |> assign(:event_id, event.id)
         |> assign(:event_name, event.name)
         |> assign(:event_status, event.status)
         |> assign(:whatsapp_sales_enabled, event.whatsapp_sales_enabled)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found.")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Event overview">
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="space-y-3">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div class="space-y-1">
              <h1 class="text-2xl font-semibold text-fc-text-primary">{@event_name}</h1>
              <p class="text-sm text-fc-text-secondary">
                Status:
                <span class="font-medium text-fc-text-primary">{format_status(@event_status)}</span>
              </p>
              <p class="text-sm text-fc-text-secondary">
                WhatsApp sales:
                <span class={whatsapp_sales_class(@whatsapp_sales_enabled)}>
                  {if @whatsapp_sales_enabled, do: "Enabled", else: "Disabled"}
                </span>
              </p>
            </div>
            <.link
              :if={@whatsapp_sales_enabled}
              navigate={~p"/dashboard/events/#{@event_id}/whatsapp-offers"}
              class="text-sm font-medium text-fc-accent hover:underline"
            >
              Manage WhatsApp tickets
            </.link>
          </div>
          <p class="text-sm text-fc-text-muted">
            Read-only cross-source summary. Attendee rows reflect scanner-visible tickets; ticket
            issues reflect Sales issuance records.
          </p>
        </header>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold text-fc-text-primary">WordPress / Tickera</h2>
          <p
            :if={tickera_empty?(@overview)}
            class="text-sm text-fc-text-secondary"
          >
            No WordPress/Tickera attendees synced for this event.
          </p>
          <div :if={!tickera_empty?(@overview)} class="grid gap-4 md:grid-cols-4">
            <.metric label="Attendees" value={@overview.attendees.tickera.total} />
            <.metric label="Scannable" value={@overview.attendees.tickera.scannable} />
            <.metric label="Not scannable" value={@overview.attendees.tickera.not_scannable} />
            <.metric label="Currently inside" value={@overview.attendees.tickera.currently_inside} />
          </div>
        </section>

        <section class="space-y-4">
          <h2 class="text-lg font-semibold text-fc-text-primary">WhatsApp / FastCheck</h2>
          <div class="grid gap-4 md:grid-cols-3">
            <.metric
              label="FastCheck attendee rows"
              value={@overview.attendees.fastcheck_sales.total}
            />
            <.metric label="WhatsApp orders" value={@overview.whatsapp.order_count} />
            <.metric label="Ticket issues" value={@overview.whatsapp.ticket_issue_count} />
          </div>

          <div
            :if={@overview.attendees.fastcheck_sales.total == 0}
            class="text-sm text-fc-text-secondary"
          >
            No FastCheck-issued attendee rows for this event yet.
          </div>
          <div
            :if={@overview.attendees.fastcheck_sales.total > 0}
            class="grid gap-4 md:grid-cols-4"
          >
            <.metric label="Scannable" value={@overview.attendees.fastcheck_sales.scannable} />
            <.metric
              label="Not scannable"
              value={@overview.attendees.fastcheck_sales.not_scannable}
            />
            <.metric
              label="Currently inside"
              value={@overview.attendees.fastcheck_sales.currently_inside}
            />
          </div>
        </section>

        <section class="grid gap-6 xl:grid-cols-2">
          <.status_panel
            title="Orders by status"
            rows={@overview.whatsapp.orders_by_status}
            empty_message="No WhatsApp/FastCheck orders for this event."
          />
          <.status_panel
            title="Ticket issues by status"
            rows={@overview.whatsapp.ticket_issues_by_status}
            empty_message="No WhatsApp ticket issues for this event."
          />
        </section>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <h2 class="text-lg font-semibold text-fc-text-primary">Ticket types (WhatsApp)</h2>
            <p
              :if={Enum.empty?(@overview.whatsapp.ticket_types)}
              class="mt-4 text-sm text-fc-text-secondary"
            >
              No WhatsApp ticket-type activity yet.
            </p>
            <div :if={!Enum.empty?(@overview.whatsapp.ticket_types)} class="mt-4 space-y-3">
              <div
                :for={row <- @overview.whatsapp.ticket_types}
                class="rounded-md border border-fc-border p-3 text-sm"
              >
                <p class="font-medium text-fc-text-primary">
                  {row.ticket_type || "Unknown type"}
                  <span :if={row.offer_name} class="text-fc-text-muted">
                    · {row.offer_name}
                  </span>
                </p>
                <p class="mt-1 text-fc-text-secondary">
                  Total ticket issues: {row.total_ticket_issues} · Issued: {row.issued}
                </p>
                <p :if={map_size(row.other_statuses) > 0} class="mt-1 text-xs text-fc-text-muted">
                  Other statuses:
                  <%= for {status, count} <- Enum.sort(row.other_statuses) do %>
                    {format_status(status)} {count};
                  <% end %>
                </p>
              </div>
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
  attr :empty_message, :string, required: true

  defp status_panel(assigns) do
    ~H"""
    <.card variant="outline" color="natural" rounded="large" padding="large">
      <.card_content>
        <h2 class="text-lg font-semibold text-fc-text-primary">{@title}</h2>
        <p :if={map_size(@rows) == 0} class="mt-4 text-sm text-fc-text-secondary">
          {@empty_message}
        </p>
        <div :if={map_size(@rows) > 0} class="mt-4 space-y-2 text-sm">
          <div :for={{label, value} <- Enum.sort(@rows)} class="flex justify-between gap-4">
            <span>{format_status(label)}</span>
            <span class="font-semibold text-fc-text-primary">{value}</span>
          </div>
        </div>
      </.card_content>
    </.card>
    """
  end

  defp tickera_empty?(overview) do
    overview.attendees.tickera.total == 0
  end

  defp whatsapp_sales_class(true), do: "font-medium text-success-dark"
  defp whatsapp_sales_class(_), do: "font-medium text-fc-text-muted"

  defp format_status(nil), do: "None"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
