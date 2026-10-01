defmodule FastCheckWeb.Operations.WorkersDashboardLive do
  @moduledoc """
  Read-only global worker and queue health dashboard.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Operations.GlobalAccess
  alias FastCheck.Operations.ObanSnapshot
  alias FastCheck.Operations.ObanSnapshot.Store

  @impl true
  def mount(_params, session, socket) do
    username = Map.get(session, "dashboard_username") || Map.get(session, :dashboard_username)

    if GlobalAccess.authorized?(username) do
      if connected?(socket), do: Store.subscribe()

      {:ok,
       socket
       |> assign(:page_title, "Global worker health")
       |> assign(:snapshot, Store.snapshot())
       |> assign(:store_state, Store.state())}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:oban_snapshot, {:snapshot, _snapshot}}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:oban_snapshot, {:lifecycle, _lifecycle}}, socket) do
    {:noreply, refresh(socket)}
  end

  defp refresh(socket) do
    assign(socket, snapshot: Store.snapshot(), store_state: Store.state())
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :rows, fn -> rows(assigns.snapshot) end)

    ~H"""
    <Layouts.app flash={@flash} breadcrumb="Global worker health">
      <div class="mx-auto max-w-7xl space-y-6 p-4">
        <header class="space-y-2">
          <h1 class="text-2xl font-semibold text-fc-text-primary">Global system worker health</h1>
          <p class="text-sm text-fc-text-secondary">
            Read-only Oban queue health for the whole FastCheck system. This view is not Event-scoped.
          </p>
        </header>

        <section class="grid gap-4 md:grid-cols-4">
          <.metric label="Monitoring status" value={format_lifecycle(@store_state[:lifecycle])} />
          <.metric label="Snapshot age" value={format_seconds(@store_state[:snapshot_age_seconds])} />
          <.metric label="Collected at" value={format_collected_at(@snapshot)} />
          <.metric label="Distribution" value={@store_state[:distribution_mode] || "unavailable"} />
        </section>

        <.card variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <div class="flex items-center justify-between gap-4">
              <h2 class="text-lg font-semibold text-fc-text-primary">Queue state</h2>
              <span class="text-xs uppercase tracking-wide text-fc-text-muted">
                Global system worker health
              </span>
            </div>
            <div class="mt-4 overflow-x-auto">
              <table class="min-w-full text-left text-sm">
                <thead class="text-xs uppercase text-fc-text-muted">
                  <tr>
                    <th class="py-2 pr-4">Queue</th>
                    <th class="py-2 pr-4">Available</th>
                    <th class="py-2 pr-4">Executing</th>
                    <th class="py-2 pr-4">Retryable</th>
                    <th class="py-2 pr-4">Scheduled</th>
                    <th class="py-2 pr-4">Discarded recent</th>
                    <th class="py-2 pr-4">Timing</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @rows} class="border-t border-fc-border">
                    <td class="py-3 pr-4 font-medium text-fc-text-primary">
                      {queue_label(row.queue)}
                    </td>
                    <td class="py-3 pr-4">{row.available}</td>
                    <td class="py-3 pr-4">{row.executing}</td>
                    <td class="py-3 pr-4">{row.retryable}</td>
                    <td class="py-3 pr-4">{row.scheduled}</td>
                    <td class="py-3 pr-4">{row.discarded_recent_count}</td>
                    <td class="py-3 pr-4 text-xs text-fc-text-secondary">
                      <div>Available age: {format_seconds(row.oldest_available_age_seconds)}</div>
                      <div>Executing age: {format_seconds(row.oldest_executing_age_seconds)}</div>
                      <div>Retryable age: {format_seconds(row.oldest_retryable_age_seconds)}</div>
                      <div>Next scheduled: {format_seconds(row.next_scheduled_in_seconds)}</div>
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
      <p class="mt-2 text-lg font-semibold text-fc-text-primary">{@value}</p>
    </div>
    """
  end

  defp rows(nil), do: Enum.map(ObanSnapshot.queue_labels(), &ObanSnapshot.empty_row/1)
  defp rows(%{queues: rows}), do: rows
  defp rows(_snapshot), do: Enum.map(ObanSnapshot.queue_labels(), &ObanSnapshot.empty_row/1)

  defp queue_label("__unexpected__"), do: "Unexpected queues"
  defp queue_label(queue), do: String.replace(queue, "_", " ") |> String.capitalize()

  defp format_lifecycle(nil), do: "Uninitialized"
  defp format_lifecycle(value), do: value |> to_string() |> String.capitalize()

  defp format_collected_at(nil), do: "None"
  defp format_collected_at(%{collected_at: %DateTime{} = value}), do: DateTime.to_iso8601(value)
  defp format_collected_at(_snapshot), do: "None"

  defp format_seconds(value) when is_number(value), do: "#{Float.round(value * 1.0, 1)}s"
  defp format_seconds(_value), do: "0.0s"
end
