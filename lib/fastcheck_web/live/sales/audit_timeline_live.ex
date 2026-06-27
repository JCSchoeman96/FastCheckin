defmodule FastCheckWeb.Sales.AuditTimelineLive do
  @moduledoc """
  Read-only, redacted Sales audit timeline.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Sales.AuditViews

  @impl true
  def mount(params, _session, socket) do
    entity_type = Map.get(params, "entity_type")
    entity_id = Map.get(params, "entity_id")

    {:ok,
     socket
     |> assign(:page_title, "Audit timeline")
     |> assign(:entity_type, entity_type)
     |> assign(:entity_id, entity_id)
     |> assign(:page, 1)
     |> load_timeline()}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    {:noreply, socket |> assign(:page, socket.assigns.page + 1) |> load_timeline()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_timeline(socket) do
    case AuditViews.timeline(socket.assigns.entity_type, socket.assigns.entity_id,
           limit: 25,
           page: socket.assigns.page
         ) do
      {:ok, timeline} ->
        socket
        |> assign(:timeline, timeline)
        |> assign(:timeline_error, nil)

      {:error, reason} ->
        socket
        |> assign(:timeline, %{entries: [], next_page: nil, page: socket.assigns.page})
        |> assign(:timeline_error, format_error(reason))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Audit timeline">
      <div class="mx-auto max-w-5xl space-y-6 p-4">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold text-fc-text-primary">Audit timeline</h1>
          <p class="text-sm text-fc-text-secondary">
            {@entity_type} {@entity_id}
          </p>
        </header>

        <p
          :if={@timeline_error}
          class="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800"
        >
          {@timeline_error}
        </p>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <div class="space-y-4">
              <p :if={Enum.empty?(@timeline.entries)} class="text-sm text-fc-text-secondary">
                No audit entries.
              </p>
              <div :for={entry <- @timeline.entries} class="rounded-md border border-fc-border p-3">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p class="font-medium text-fc-text-primary">
                    {format_status(entry.source || entry.entity_type)}
                  </p>
                  <p class="text-xs text-fc-text-muted">{format_timestamp(entry.timestamp)}</p>
                </div>
                <p class="mt-2 text-sm text-fc-text-secondary">
                  {format_status(entry.from_state)} → {format_status(entry.to_state)}
                </p>
                <p class="mt-1 text-xs text-fc-text-muted">
                  Reason: {entry.reason_code || "none"} · Actor: {entry.actor_type || "unknown"}
                </p>
                <dl
                  :if={map_size(entry.metadata || %{}) > 0}
                  class="mt-3 grid gap-2 text-xs md:grid-cols-2"
                >
                  <div :for={{key, value} <- Enum.sort(entry.metadata)}>
                    <dt class="font-semibold text-fc-text-muted">{key}</dt>
                    <dd class="break-words text-fc-text-secondary">{inspect(value)}</dd>
                  </div>
                </dl>
              </div>
            </div>

            <div :if={@timeline.next_page} class="mt-4">
              <.button type="button" variant="outline" color="primary" phx-click="next_page">
                Next page
              </.button>
            </div>
          </.card_content>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp format_error(:invalid_entity_type), do: "Unsupported audit entity type"
  defp format_error(:invalid_entity_id), do: "Invalid audit entity id"
  defp format_error(_), do: "Audit timeline unavailable"

  defp format_timestamp(nil), do: "Unknown time"
  defp format_timestamp(timestamp), do: Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")

  defp format_status(nil), do: "none"

  defp format_status(status),
    do: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
