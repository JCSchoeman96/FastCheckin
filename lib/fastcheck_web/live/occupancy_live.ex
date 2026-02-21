defmodule FastCheckWeb.OccupancyLive do
  @moduledoc """
  Immersive real-time occupancy dashboard for operations teams to monitor gate
  pressure, alerts, and entrance level performance.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.Events
  alias Phoenix.PubSub

  @impl true
  def mount(%{"event_id" => event_id_param}, _session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, event} <- fetch_event(event_id) do
      stats = Events.get_event_advanced_stats(event_id)

      socket =
        socket
        |> assign(:event_id, event_id)
        |> assign_dashboard(event, stats)

      if connected?(socket) do
        PubSub.subscribe(FastCheck.PubSub, occupancy_topic(event_id))
      end

      {:ok, socket}
    else
      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/")}
    end
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> put_flash(:error, "Missing event context")
     |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_info({:occupancy_changed, _count, _type}, socket) do
    event = Events.get_event_with_stats(socket.assigns.event_id)
    stats = Events.get_event_advanced_stats(socket.assigns.event_id)

    {:noreply, assign_dashboard(socket, event, stats)}
  end

  def handle_info({:occupancy_update, %{event_id: event_id} = payload}, socket)
      when event_id == socket.assigns.event_id do
    percentage = payload.percentage |> normalize_percentage()
    counts = Map.put(socket.assigns.counts, :currently_inside, payload.inside_count || 0)

    socket =
      socket
      |> assign(:counts, counts)
      |> assign(:capacity, payload.capacity || socket.assigns.capacity)
      |> assign(:percentage, percentage)
      |> assign(:alerts, generate_alerts(percentage))
      |> assign(:last_updated, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:stats_cards, stats_cards(assigns.counts))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen space-y-6 sm:space-y-8 bg-scanner-dark">
        <%!-- Header --%>
        <.card variant="outline" color="natural" rounded="large" padding="large" class="glass-card glass-sheen glass-card-deep">
          <.card_content>
            <p
              style="font-size: var(--fc-text-xs)"
              class="uppercase tracking-[0.35em] text-fc-text-muted"
            >
              Live occupancy feed
            </p>

            <h1 style="font-size: var(--fc-text-3xl)" class="mt-3 font-semibold text-fc-text-primary">
              {@event.name}
            </h1>

            <div class="mt-6 flex flex-col gap-4 text-sm text-fc-text-secondary sm:flex-row sm:items-center sm:justify-between">
              <div class="flex flex-wrap items-center gap-4">
                <div>
                  <p
                    style="font-size: var(--fc-text-xs)"
                    class="uppercase tracking-[0.3em] text-fc-text-muted"
                  >
                    Location
                  </p>
                  <p class="text-base font-medium text-fc-text-primary">
                    {format_field(@event.location, "To be announced")}
                  </p>
                </div>

                <div>
                  <p
                    style="font-size: var(--fc-text-xs)"
                    class="uppercase tracking-[0.3em] text-fc-text-muted"
                  >
                    Entrance
                  </p>
                  <p class="text-base font-medium text-fc-text-primary">
                    {format_field(@event.entrance_name, "Any gate")}
                  </p>
                </div>
              </div>

              <div class="flex flex-wrap items-center gap-4">
                <div>
                  <p
                    style="font-size: var(--fc-text-xs)"
                    class="uppercase tracking-[0.3em] text-fc-text-muted"
                  >
                    Date
                  </p>
                  <p class="text-base font-medium text-fc-text-primary">
                    {format_event_date(@event.event_date)}
                  </p>
                </div>

                <div>
                  <p
                    style="font-size: var(--fc-text-xs)"
                    class="uppercase tracking-[0.3em] text-fc-text-muted"
                  >
                    Gates open
                  </p>
                  <p class="text-base font-medium text-fc-text-primary">
                    {format_event_time(@event.event_time)}
                  </p>
                </div>
              </div>
            </div>
          </.card_content>
        </.card>

        <%!-- Occupancy gauge + Flow summary --%>
        <section class="grid gap-6 lg:grid-cols-[1.1fr_0.9fr]">
          <.card
            variant="base"
            color={occupancy_card_color(@percentage)}
            rounded="large"
            padding="large"
          >
            <.card_content>
              <div class="flex flex-col gap-2">
                <p class="text-sm uppercase tracking-[0.3em] opacity-80">Occupancy</p>

                <div class="flex flex-wrap items-baseline gap-3">
                  <p style="font-size: var(--fc-text-4xl)" class="font-semibold">
                    {format_percentage(@percentage)}
                  </p>
                  <span class="text-lg opacity-80">live</span>
                </div>

                <p class="text-sm opacity-90">
                  {format_count(@counts.currently_inside)} inside · Capacity {format_count(@capacity)}
                </p>
              </div>

              <.progress
                value={progress_width(@percentage)}
                color={occupancy_card_color(@percentage)}
                size="small"
                class="mt-6"
              />

              <p class="mt-2 text-xs uppercase tracking-[0.25em] opacity-70">
                Crowd saturation meter
              </p>

              <div :if={Enum.any?(@alerts)} class="mt-6 space-y-3">
                <.alert
                  :for={alert <- @alerts}
                  kind={:warning}
                  variant="bordered"
                  size="small"
                  rounded="large"
                >
                  {alert}
                </.alert>
              </div>
            </.card_content>
          </.card>

          <.card variant="outline" color="natural" rounded="large" padding="large" class="glass-card glass-sheen">
            <.card_content>
              <p class="text-sm uppercase tracking-[0.3em] text-fc-text-muted">Flow summary</p>

              <dl class="mt-6 space-y-4 text-sm">
                <div class="flex items-center justify-between">
                  <dt class="text-fc-text-secondary">Checked in today</dt>
                  <dd class="text-base font-semibold text-fc-text-primary">
                    {format_count(@counts.scans_today)}
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-fc-text-secondary">Total entries</dt>
                  <dd class="text-base font-semibold text-fc-text-primary">
                    {format_count(@counts.total_entries)}
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-fc-text-secondary">Total exits</dt>
                  <dd class="text-base font-semibold text-fc-text-primary">
                    {format_count(@counts.total_exits)}
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-fc-text-secondary">Available tomorrow</dt>
                  <dd class="text-base font-semibold text-fc-text-primary">
                    {format_count(@counts.available_tomorrow)}
                  </dd>
                </div>

                <div class="flex items-center justify-between">
                  <dt class="text-fc-text-secondary">Avg session</dt>
                  <dd class="text-base font-semibold text-fc-text-primary">
                    {format_minutes(@counts.average_session_minutes)}
                  </dd>
                </div>
              </dl>
            </.card_content>
          </.card>
        </section>

        <%!-- Gate distribution --%>
        <section class="space-y-4">
          <div class="flex flex-col gap-2">
            <p
              style="font-size: var(--fc-text-xs)"
              class="uppercase tracking-[0.35em] text-fc-text-muted"
            >
              Per entrance performance
            </p>
            <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
              Gate distribution
            </h2>
          </div>

          <div :if={Enum.any?(@per_entrance)} class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
            <.card
              :for={entrance <- @per_entrance}
              variant="outline"
              color="natural"
              rounded="large"
              padding="medium"
              class="fc-card-container glass-card glass-sheen"
            >
              <.card_content>
                <p class="text-sm uppercase tracking-[0.3em] text-fc-text-muted">
                  {entrance.entrance_name}
                </p>

                <p
                  style="font-size: var(--fc-text-3xl)"
                  class="mt-3 font-semibold text-fc-text-primary"
                >
                  {format_count(entrance.inside)}
                </p>

                <p class="text-sm text-fc-text-secondary">Currently inside</p>

                <div class="mt-6 grid grid-cols-3 gap-2 text-center text-sm">
                  <div class="rounded-xl bg-fc-surface-overlay dark:bg-glass-bg dark:border dark:border-glass-border px-3 py-2">
                    <p
                      style="font-size: var(--fc-text-xs)"
                      class="uppercase tracking-[0.3em] text-fc-text-muted"
                    >
                      Entries
                    </p>
                    <p class="mt-1 text-lg font-semibold text-fc-text-primary">
                      {format_count(entrance.entries)}
                    </p>
                  </div>

                  <div class="rounded-xl bg-fc-surface-overlay dark:bg-glass-bg dark:border dark:border-glass-border px-3 py-2">
                    <p
                      style="font-size: var(--fc-text-xs)"
                      class="uppercase tracking-[0.3em] text-fc-text-muted"
                    >
                      Exits
                    </p>
                    <p class="mt-1 text-lg font-semibold text-fc-text-primary">
                      {format_count(entrance.exits)}
                    </p>
                  </div>

                  <div class="rounded-xl bg-fc-surface-overlay dark:bg-glass-bg dark:border dark:border-glass-border px-3 py-2">
                    <p
                      style="font-size: var(--fc-text-xs)"
                      class="uppercase tracking-[0.3em] text-fc-text-muted"
                    >
                      Net
                    </p>
                    <p class="mt-1 text-lg font-semibold text-fc-text-primary">
                      {format_count(entrance.entries - entrance.exits)}
                    </p>
                  </div>
                </div>
              </.card_content>
            </.card>
          </div>

          <div
            :if={!Enum.any?(@per_entrance)}
            class="rounded-2xl border border-dashed border-fc-border-default dark:border-glass-border bg-fc-surface-raised dark:bg-glass-bg p-8 text-center text-sm text-fc-text-muted"
          >
            Entrance-level analytics will appear as soon as check-ins stream in.
          </div>
        </section>

        <%!-- Operational snapshot --%>
        <section class="space-y-4">
          <div class="flex flex-col gap-2">
            <p
              style="font-size: var(--fc-text-xs)"
              class="uppercase tracking-[0.35em] text-fc-text-muted"
            >
              At-a-glance
            </p>
            <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
              Operational snapshot
            </h2>
          </div>

          <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.card
              :for={card <- @stats_cards}
              variant="outline"
              color="natural"
              rounded="large"
              padding="small"
              class="glass-card"
            >
              <.card_content>
                <p
                  style="font-size: var(--fc-text-xs)"
                  class="uppercase tracking-[0.35em] text-fc-text-muted"
                >
                  {card.label}
                </p>
                <p
                  style="font-size: var(--fc-text-3xl)"
                  class="mt-3 font-semibold text-fc-text-primary"
                >
                  {card.value}
                </p>
                <p class="text-sm text-fc-text-secondary">{card.hint}</p>
              </.card_content>
            </.card>
          </div>
        </section>

        <%!-- Footer --%>
        <footer class="flex flex-col items-start gap-2 border-t border-fc-border-default pt-6 text-sm text-fc-text-secondary sm:flex-row sm:items-center sm:justify-between">
          <p>Last updated {format_timestamp(@last_updated)}</p>
          <p
            style="font-size: var(--fc-text-xs)"
            class="uppercase tracking-[0.35em] text-fc-text-muted"
          >
            Topic: {occupancy_topic(@event_id)}
          </p>
        </footer>
      </div>
    </Layouts.app>
    """
  end

  defp assign_dashboard(socket, event, stats) do
    per_entrance = stats |> Map.get(:per_entrance, []) |> normalize_per_entrance()
    percentage = stats |> Map.get(:occupancy_percentage, 0.0) |> normalize_percentage()
    capacity = event.total_tickets || Map.get(stats, :total_attendees, 0) || 0

    counts = %{
      total: Map.get(stats, :total_attendees, capacity),
      checked_in: Map.get(stats, :checked_in, 0),
      pending: Map.get(stats, :pending, 0),
      currently_inside: Map.get(stats, :currently_inside, 0),
      scans_today: Map.get(stats, :scans_today, 0),
      total_entries: Map.get(stats, :total_entries, 0),
      total_exits: Map.get(stats, :total_exits, 0),
      available_tomorrow: Map.get(stats, :available_tomorrow, 0),
      average_session_minutes: Map.get(stats, :average_session_duration_minutes, 0.0)
    }

    socket
    |> assign(:event, event)
    |> assign(:capacity, capacity)
    |> assign(:counts, counts)
    |> assign(:per_entrance, per_entrance)
    |> assign(:percentage, percentage)
    |> assign(:alerts, generate_alerts(percentage))
    |> assign(:last_updated, DateTime.utc_now())
  end

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid}
    end
  end

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_event_id(_), do: {:error, :invalid}

  defp fetch_event(event_id) do
    {:ok, Events.get_event_with_stats(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp occupancy_topic(event_id), do: "event:#{event_id}:occupancy"

  defp normalize_percentage(value) when is_float(value), do: Float.round(max(value, 0.0), 1)
  defp normalize_percentage(value) when is_integer(value), do: normalize_percentage(value / 1)
  defp normalize_percentage(_), do: 0.0

  defp normalize_per_entrance(list) when is_list(list) do
    list
    |> Enum.map(fn entrance ->
      %{
        entrance_name: Map.get(entrance, :entrance_name, "Entrance"),
        entries: Map.get(entrance, :entries, 0),
        exits: Map.get(entrance, :exits, 0),
        inside: Map.get(entrance, :inside, 0)
      }
    end)
    |> Enum.sort_by(& &1.inside, :desc)
  end

  defp normalize_per_entrance(_), do: []

  defp occupancy_card_color(percentage) when percentage >= 95, do: "danger"
  defp occupancy_card_color(percentage) when percentage >= 80, do: "warning"
  defp occupancy_card_color(_percentage), do: "success"

  defp progress_width(percentage) do
    percentage
    |> min(100.0)
    |> max(0.0)
  end

  defp generate_alerts(percentage) when is_number(percentage) do
    []
    |> maybe_add_alert(percentage >= 75, "Approaching capacity — coordinate guest flow.")
    |> maybe_add_alert(percentage >= 90, "Critical density — deploy additional entrance staff.")
    |> maybe_add_alert(
      percentage >= 100,
      "Capacity exceeded — halt entry and trigger overflow plan."
    )
  end

  defp maybe_add_alert(alerts, true, message), do: alerts ++ [message]
  defp maybe_add_alert(alerts, false, _message), do: alerts

  defp stats_cards(counts) do
    [
      %{label: "Total tickets", value: format_count(counts.total), hint: "Capacity configured"},
      %{label: "Checked in", value: format_count(counts.checked_in), hint: "Lifetime"},
      %{
        label: "Currently inside",
        value: format_count(counts.currently_inside),
        hint: "Live occupancy"
      },
      %{
        label: "Pending arrival",
        value: format_count(counts.pending),
        hint: "Guests yet to arrive"
      },
      %{label: "Scans today", value: format_count(counts.scans_today), hint: "Since midnight"},
      %{
        label: "Total entries",
        value: format_count(counts.total_entries),
        hint: "All recorded entries"
      },
      %{label: "Total exits", value: format_count(counts.total_exits), hint: "Guests that left"},
      %{
        label: "Available tomorrow",
        value: format_count(counts.available_tomorrow),
        hint: "Remaining allowance"
      },
      %{
        label: "Avg stay",
        value: format_minutes(counts.average_session_minutes),
        hint: "Average session"
      }
    ]
  end

  defp format_percentage(value) when is_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> Kernel.<>("%")
  end

  defp format_percentage(_), do: "0.0%"

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)

  defp format_count(value) when is_float(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_count(_), do: "0"

  defp format_minutes(value) when is_number(value) do
    value
    |> max(0.0)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> Kernel.<>(" min")
  end

  defp format_minutes(_), do: "—"

  defp format_timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%b %d · %H:%M UTC")
  end

  defp format_timestamp(_), do: "just now"

  defp format_field(nil, fallback), do: fallback
  defp format_field("", fallback), do: fallback
  defp format_field(value, _fallback), do: value

  defp format_event_date(%Date{} = date), do: Calendar.strftime(date, "%b %d, %Y")
  defp format_event_date(_), do: "TBD"

  defp format_event_time(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp format_event_time(_), do: "--:--"
end
