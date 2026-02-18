defmodule FastCheckWeb.DashboardLive do
  @moduledoc """
  Admin dashboard for managing events, launching attendee syncs, and
  monitoring high-level statistics.
  """

  use FastCheckWeb, :live_view

  alias Ecto.Changeset
  alias FastCheck.Events
  alias FastCheck.Events.Event

  @impl true
  def mount(_params, _session, socket) do
    events = Events.list_events()

    {:ok,
     socket
     |> assign(:events, events)
     |> assign(:filtered_events, events)
     |> assign(:search_query, "")
     |> assign(:selected_event_id, nil)
     |> assign(:show_new_event_form, false)
     |> assign(:editing_event_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:sync_progress, nil)
     |> assign(:sync_start_time, nil)
     |> assign(:sync_timing_data, [])
     |> assign(:sync_status, nil)
     |> assign(:sync_paused, false)
     |> assign(:sync_task_pid, nil)
     |> assign(:viewing_sync_history_for, nil)
     |> assign(:sync_history, [])
     |> assign(:form, empty_event_form())}
  end

  @impl true
  def handle_event("show_new_event_form", _params, socket) do
    {:noreply, assign(socket, :show_new_event_form, true)}
  end

  @impl true
  def handle_event("hide_new_event_form", _params, socket) do
    {:noreply, assign(socket, :show_new_event_form, false)}
  end

  @impl true
  def handle_event("create_event", %{"event" => event_params}, socket) do
    case Events.create_event(event_params) do
      {:ok, event} ->
        updated_events = [event | socket.assigns.events]

        {:noreply,
         socket
         |> assign(:events, updated_events)
         |> assign(:show_new_event_form, false)
         |> assign(:sync_status, "Event created successfully")
         |> assign(:form, empty_event_form())}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:sync_status, "Unable to create event: #{format_error(changeset)}")
         |> assign(:form, to_form(changeset))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:sync_status, "Unable to create event: #{format_error(reason)}")
         |> assign(:form, sticky_event_form(event_params))}
    end
  end

  def handle_event("create_event", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Invalid event payload")}
  end

  @impl true
  def handle_event("start_sync", %{"event_id" => event_id_param} = params, socket) do
    incremental = Map.get(params, "incremental", "false") == "true"

    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, pid} <- start_sync_task(event_id, incremental: incremental) do
      start_time = System.monotonic_time(:second)
      sync_type = if incremental, do: "incremental", else: "full"

      {:noreply,
       socket
       |> assign(:selected_event_id, event_id)
       |> assign(:sync_progress, {0, 0, 0})
       |> assign(:sync_start_time, start_time)
       |> assign(:sync_timing_data, [])
       |> assign(:sync_paused, false)
       |> assign(:sync_task_pid, pid)
       |> assign(:sync_status, "Starting #{sync_type} attendee sync...")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :sync_status, reason)}
    end
  end

  def handle_event("start_sync", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("search_events", %{"query" => query}, socket) do
    filtered = filter_events(socket.assigns.events, query)

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:filtered_events, filtered)}
  end

  def handle_event("search_events", _params, socket) do
    {:noreply,
     assign(socket, :search_query, "") |> assign(:filtered_events, socket.assigns.events)}
  end

  @impl true
  def handle_event("archive_event", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, _event} <- Events.archive_event(event_id) do
      refreshed_events = Events.list_events()

      {:noreply,
       socket
       |> assign(:events, refreshed_events)
       |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
       |> assign(:sync_status, "Event archived successfully")}
    else
      {:error, reason} ->
        {:noreply,
         assign(socket, :sync_status, "Failed to archive event: #{format_error(reason)}")}
    end
  end

  def handle_event("archive_event", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("unarchive_event", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, _event} <- Events.unarchive_event(event_id) do
      refreshed_events = Events.list_events()

      {:noreply,
       socket
       |> assign(:events, refreshed_events)
       |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
       |> assign(:sync_status, "Event unarchived successfully")}
    else
      {:error, reason} ->
        {:noreply,
         assign(socket, :sync_status, "Failed to unarchive event: #{format_error(reason)}")}
    end
  end

  def handle_event("unarchive_event", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("show_edit_form", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         %Event{} = event <- Events.get_event!(event_id) do
      edit_form = build_edit_form(event)

      {:noreply,
       socket
       |> assign(:editing_event_id, event_id)
       |> assign(:edit_form, edit_form)}
    else
      _ ->
        {:noreply, assign(socket, :sync_status, "Event not found")}
    end
  end

  def handle_event("show_edit_form", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("hide_edit_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_event_id, nil)
     |> assign(:edit_form, nil)}
  end

  @impl true
  def handle_event("update_event", %{"event" => event_params}, socket) do
    event_id = socket.assigns.editing_event_id

    if event_id do
      case Events.update_event(event_id, event_params) do
        {:ok, _event} ->
          refreshed_events = Events.list_events()

          {:noreply,
           socket
           |> assign(:events, refreshed_events)
           |> assign(
             :filtered_events,
             filter_events(refreshed_events, socket.assigns.search_query)
           )
           |> assign(:editing_event_id, nil)
           |> assign(:edit_form, nil)
           |> assign(:sync_status, "Event updated successfully")}

        {:error, %Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:sync_status, "Unable to update event: #{format_error(changeset)}")
           |> assign(:edit_form, to_form(changeset))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:sync_status, "Unable to update event: #{format_error(reason)}")
           |> assign(:edit_form, socket.assigns.edit_form)}
      end
    else
      {:noreply, assign(socket, :sync_status, "No event selected for editing")}
    end
  end

  def handle_event("update_event", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Invalid event payload")}
  end

  @impl true
  def handle_event("pause_sync", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param) do
      FastCheck.Events.SyncState.pause_sync(event_id)

      {:noreply,
       socket
       |> assign(:sync_paused, true)
       |> assign(:sync_status, "Sync paused")}
    else
      _ ->
        {:noreply, assign(socket, :sync_status, "Invalid event identifier")}
    end
  end

  def handle_event("pause_sync", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("resume_sync", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param) do
      FastCheck.Events.SyncState.resume_sync(event_id)

      {:noreply,
       socket
       |> assign(:sync_paused, false)
       |> assign(:sync_status, "Sync resumed")}
    else
      _ ->
        {:noreply, assign(socket, :sync_status, "Invalid event identifier")}
    end
  end

  def handle_event("resume_sync", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("cancel_sync", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param) do
      FastCheck.Events.SyncState.cancel_sync(event_id)

      {:noreply,
       socket
       |> assign(:sync_progress, nil)
       |> assign(:sync_paused, false)
       |> assign(:sync_status, "Sync cancelled")
       |> assign(:sync_start_time, nil)
       |> assign(:sync_timing_data, [])}
    else
      _ ->
        {:noreply, assign(socket, :sync_status, "Invalid event identifier")}
    end
  end

  def handle_event("cancel_sync", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("show_sync_history", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param) do
      sync_history = Events.list_event_sync_logs(event_id, 10)

      {:noreply,
       socket
       |> assign(:viewing_sync_history_for, event_id)
       |> assign(:sync_history, sync_history)}
    else
      _ ->
        {:noreply, assign(socket, :sync_status, "Invalid event identifier")}
    end
  end

  def handle_event("show_sync_history", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event("hide_sync_history", _params, socket) do
    {:noreply,
     socket
     |> assign(:viewing_sync_history_for, nil)
     |> assign(:sync_history, [])}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_progress, page, total, count}, socket) do
    # Track timing data for estimation
    current_time = System.monotonic_time(:second)
    start_time = socket.assigns.sync_start_time || current_time
    elapsed_seconds = current_time - start_time

    # Update timing data (keep last 5 page timings for better accuracy)
    timing_data =
      [%{page: page, elapsed: elapsed_seconds} | socket.assigns.sync_timing_data]
      |> Enum.take(5)

    # Calculate average time per page
    avg_time_per_page = calculate_avg_time_per_page(timing_data, page)

    # Estimate remaining time
    remaining_pages = max(0, (total || 0) - page)

    estimated_remaining_seconds =
      if avg_time_per_page > 0 and remaining_pages > 0 do
        round(remaining_pages * avg_time_per_page)
      else
        nil
      end

    status = progress_status(page, total, count, estimated_remaining_seconds)

    {:noreply,
     socket
     |> assign(:sync_progress, {page, total, count})
     |> assign(:sync_timing_data, timing_data)
     |> assign(:sync_status, status)}
  end

  @impl true
  def handle_info({:sync_error, message}, socket) do
    {:noreply, assign(socket, :sync_status, "Sync failed: #{message}")}
  end

  @impl true
  def handle_info(:sync_complete, socket) do
    refreshed_events = Events.list_events()

    final_status =
      case socket.assigns.sync_status do
        nil -> "Sync complete!"
        "Sync failed" <> _rest -> socket.assigns.sync_status
        _ -> "Sync complete!"
      end

    {:noreply,
     socket
     |> assign(:events, refreshed_events)
     |> assign(:sync_progress, nil)
     |> assign(:sync_start_time, nil)
     |> assign(:sync_timing_data, [])
     |> assign(:sync_paused, false)
     |> assign(:sync_task_pid, nil)
     |> assign(:sync_status, final_status)
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl space-y-6 sm:space-y-8 px-2 sm:px-4 py-6 sm:py-10">
        <div class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          <div>
            <p class="text-sm uppercase tracking-widest text-slate-500">Control Center</p>

            <h1 class="text-2xl sm:text-3xl font-semibold text-slate-900">FastCheck Dashboard</h1>
          </div>

          <div class="flex items-center gap-3">
            <button
              type="button"
              phx-click="show_new_event_form"
              class="rounded-md bg-blue-600 px-5 py-2 text-sm font-semibold text-white shadow hover:bg-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
            >
              + New Event
            </button>
          </div>
        </div>

        <div :if={@sync_status} class="rounded-xl bg-white p-6 shadow">
          <div class="flex flex-col gap-4">
            <div class="flex items-center justify-between">
              <div>
                <p class="text-sm font-medium text-slate-600">Sync status</p>

                <p class="text-base font-semibold text-slate-900">{@sync_status}</p>
              </div>
            </div>

            <div :if={@sync_progress} class="w-full rounded-full bg-slate-100 p-1">
              <div
                class="h-3 rounded-full bg-blue-600 transition-all"
                style={"width: #{progress_percent(@sync_progress)}%"}
              />
              <p class="mt-2 text-xs font-medium text-slate-500">
                {progress_details(@sync_progress)}
              </p>
            </div>
          </div>
        </div>

        <div :if={@show_new_event_form} class="rounded-2xl bg-white p-8 shadow">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-2xl font-semibold text-slate-900">Create new event</h2>

              <p class="text-sm text-slate-500">
                Connect a Tickera event by providing its credentials and entrance details.
              </p>
            </div>

            <button
              type="button"
              class="text-sm font-medium text-slate-500 hover:text-slate-800"
              phx-click="hide_new_event_form"
            >
              Cancel
            </button>
          </div>

          <.form
            for={@form}
            phx-submit="create_event"
            class="mt-6 grid grid-cols-1 gap-6 md:grid-cols-2"
          >
            <.input
              field={@form[:name]}
              type="text"
              label="Event name"
              placeholder="Tech Summit 2024"
            />
            <.input
              field={@form[:tickera_site_url]}
              type="text"
              label="Site URL"
              placeholder="https://example.com"
            />
            <.input
              field={@form[:tickera_api_key_encrypted]}
              type="password"
              label="Tickera API Key"
              placeholder="••••••"
            />
            <.input
              field={@form[:mobile_access_code]}
              type="password"
              label="Mobile access code"
              placeholder="Required for scanner login"
            />
            <.input
              field={@form[:location]}
              type="text"
              label="Location"
              placeholder="Cape Town Convention Centre"
            />
            <.input
              field={@form[:entrance_name]}
              type="text"
              label="Entrance Name"
              placeholder="Main Gate"
            />
            <div class="md:col-span-2 flex items-center gap-3">
              <button
                type="submit"
                class="inline-flex items-center rounded-md bg-blue-600 px-6 py-3 text-sm font-semibold text-white shadow transition hover:bg-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
                phx-disable-with="Creating..."
              >
                Create Event
              </button>
              <button
                type="button"
                class="text-sm font-medium text-slate-500 hover:text-slate-800"
                phx-click="hide_new_event_form"
              >
                Nevermind
              </button>
            </div>
          </.form>
        </div>

        <div class="space-y-4">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="text-2xl font-semibold text-slate-900">Events</h2>

              <p class="text-sm text-slate-500">
                Manage entrances, sync attendees, and launch scanners.
              </p>
            </div>

            <div class="flex-1 sm:max-w-md">
              <.form
                for={to_form(%{"query" => @search_query})}
                phx-change="search_events"
                class="relative"
              >
                <.input
                  field={to_form(%{"query" => @search_query})[:query]}
                  type="search"
                  placeholder="Search events by name, location..."
                  phx-debounce="300"
                  class="w-full rounded-lg border border-slate-300 px-4 py-2 pr-10 text-sm focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200"
                />
                <button
                  :if={@search_query != ""}
                  type="button"
                  phx-click="search_events"
                  phx-value-query=""
                  class="absolute right-2 top-1/2 -translate-y-1/2 text-slate-400 hover:text-slate-600"
                  aria-label="Clear search"
                >
                  <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M6 18L18 6M6 6l12 12"
                    />
                  </svg>
                </button>
              </.form>
            </div>
          </div>

          <div class="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
            <div
              :for={event <- @filtered_events}
              class={[
                "rounded-2xl border border-slate-200 bg-white p-6 shadow transition hover:-translate-y-1 hover:shadow-lg",
                @selected_event_id == event.id && "ring-2 ring-blue-500"
              ]}
            >
              <% lifecycle_state = Events.event_lifecycle_state(event) %>
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="text-sm uppercase tracking-wide text-slate-400">
                    {event.location || "Unassigned"}
                  </p>

                  <h3 class="mt-1 text-xl font-semibold text-slate-900">{event.name}</h3>
                </div>

                <div class="flex flex-col items-end gap-2 text-right">
                  <span class="rounded-full bg-blue-50 px-3 py-1 text-xs font-semibold text-blue-700">
                    {event.entrance_name || "Entrance"}
                  </span>
                  <span class={[
                    "rounded-full px-3 py-1 text-xs font-semibold",
                    lifecycle_badge_class(lifecycle_state)
                  ]}>
                    {lifecycle_label(lifecycle_state)}
                  </span>
                </div>
              </div>

              <div class="mt-6 grid grid-cols-2 gap-4 text-center md:grid-cols-3">
                <div class="rounded-xl bg-slate-50 p-4">
                  <p class="text-xs uppercase tracking-wide text-slate-500">Total tickets</p>

                  <p class="text-2xl font-semibold text-slate-900">{event.total_tickets || 0}</p>
                </div>

                <div class="rounded-xl bg-slate-50 p-4">
                  <p class="text-xs uppercase tracking-wide text-slate-500">Checked in</p>

                  <p class="text-2xl font-semibold text-green-600">{event.checked_in_count || 0}</p>
                </div>

                <div class="rounded-xl bg-slate-50 p-4">
                  <p class="text-xs uppercase tracking-wide text-slate-500">Total attendees</p>

                  <p class="text-2xl font-semibold text-slate-900">{event.attendee_count || 0}</p>
                </div>
              </div>

              <div class="mt-6 flex flex-wrap gap-3">
                <div
                  :if={@selected_event_id != event.id || @sync_progress == nil}
                  class="flex-1 flex gap-2"
                >
                  <button
                    type="button"
                    class={[
                      "flex-1 rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2",
                      lifecycle_state == :archived && "cursor-not-allowed opacity-60"
                    ]}
                    phx-click="start_sync"
                    phx-value-event_id={event.id}
                    phx-value-incremental="false"
                    phx-disable-with="Syncing..."
                    disabled={lifecycle_state == :archived}
                    aria-disabled={lifecycle_state == :archived}
                  >
                    Full Sync
                  </button>
                  <button
                    type="button"
                    class={[
                      "flex-1 rounded-md bg-green-600 px-4 py-2 text-sm font-semibold text-white shadow focus:outline-none focus:ring-2 focus:ring-green-400 focus:ring-offset-2",
                      lifecycle_state == :archived && "cursor-not-allowed opacity-60"
                    ]}
                    phx-click="start_sync"
                    phx-value-event_id={event.id}
                    phx-value-incremental="true"
                    phx-disable-with="Syncing..."
                    disabled={lifecycle_state == :archived}
                    aria-disabled={lifecycle_state == :archived}
                    title="Only sync new or updated attendees (faster)"
                  >
                    Incremental Sync
                  </button>
                </div>

                <div
                  :if={@selected_event_id == event.id && @sync_progress != nil}
                  class="flex-1 flex gap-2"
                >
                  <button
                    :if={!@sync_paused}
                    type="button"
                    phx-click="pause_sync"
                    phx-value-event_id={event.id}
                    class="flex-1 rounded-md bg-yellow-600 px-4 py-2 text-sm font-semibold text-white shadow focus:outline-none focus:ring-2 focus:ring-yellow-400 focus:ring-offset-2"
                  >
                    ⏸ Pause
                  </button>
                  <button
                    :if={@sync_paused}
                    type="button"
                    phx-click="resume_sync"
                    phx-value-event_id={event.id}
                    class="flex-1 rounded-md bg-green-600 px-4 py-2 text-sm font-semibold text-white shadow focus:outline-none focus:ring-2 focus:ring-green-400 focus:ring-offset-2"
                  >
                    ▶ Resume
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_sync"
                    phx-value-event_id={event.id}
                    class="flex-1 rounded-md bg-red-600 px-4 py-2 text-sm font-semibold text-white shadow focus:outline-none focus:ring-2 focus:ring-red-400 focus:ring-offset-2"
                  >
                    ✕ Cancel
                  </button>
                </div>

                <a
                  href={if lifecycle_state == :archived, do: "#", else: "/scan/#{event.id}"}
                  class={[
                    "flex-1 rounded-md border border-slate-200 px-4 py-2 text-center text-sm font-semibold text-slate-700 transition hover:border-slate-300 hover:text-slate-900",
                    lifecycle_state == :archived &&
                      "cursor-not-allowed opacity-60 pointer-events-none"
                  ]}
                  aria-disabled={lifecycle_state == :archived}
                >
                  Open scanner
                </a>
                <button
                  :if={lifecycle_state != :archived}
                  type="button"
                  phx-click="show_edit_form"
                  phx-value-event_id={event.id}
                  class="w-full rounded-md border border-blue-300 bg-blue-50 px-4 py-2 text-sm font-semibold text-blue-700 transition hover:bg-blue-100 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
                >
                  Edit Event
                </button>
                <div :if={lifecycle_state != :archived} class="w-full flex gap-2">
                  <a
                    href={~p"/export/attendees/#{event.id}"}
                    class="flex-1 rounded-md border border-green-300 bg-green-50 px-3 py-2 text-center text-xs font-semibold text-green-700 transition hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-400 focus:ring-offset-2"
                  >
                    Export Attendees
                  </a>
                  <a
                    href={~p"/export/check-ins/#{event.id}"}
                    class="flex-1 rounded-md border border-green-300 bg-green-50 px-3 py-2 text-center text-xs font-semibold text-green-700 transition hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-400 focus:ring-offset-2"
                  >
                    Export Check-ins
                  </a>
                </div>

                <button
                  :if={lifecycle_state != :archived}
                  type="button"
                  phx-click="archive_event"
                  phx-value-event_id={event.id}
                  class="w-full rounded-md border border-red-300 bg-red-50 px-4 py-2 text-sm font-semibold text-red-700 transition hover:bg-red-100 focus:outline-none focus:ring-2 focus:ring-red-400 focus:ring-offset-2"
                  data-confirm="Archive this event? Archived events cannot be synced or scanned."
                >
                  Archive Event
                </button>
                <button
                  :if={lifecycle_state == :archived}
                  type="button"
                  phx-click="unarchive_event"
                  phx-value-event_id={event.id}
                  class="w-full rounded-md border border-green-300 bg-green-50 px-4 py-2 text-sm font-semibold text-green-700 transition hover:bg-green-100 focus:outline-none focus:ring-2 focus:ring-green-400 focus:ring-offset-2"
                >
                  Unarchive Event
                </button>
                <p
                  :if={lifecycle_state == :archived}
                  class="w-full text-xs text-red-500"
                >
                  Scanning disabled for archived events
                </p>
              </div>
            </div>

            <div
              :if={Enum.empty?(@filtered_events) && @search_query != ""}
              class="col-span-full rounded-2xl border border-dashed border-slate-300 p-10 text-center"
            >
              <p class="text-lg font-semibold text-slate-700">No events found</p>

              <p class="mt-2 text-sm text-slate-500">
                No events match "{@search_query}". Try a different search term.
              </p>
            </div>

            <div
              :if={Enum.empty?(@filtered_events) && @search_query == ""}
              class="col-span-full rounded-2xl border border-dashed border-slate-300 p-10 text-center"
            >
              <p class="text-lg font-semibold text-slate-700">No events yet</p>

              <p class="mt-2 text-sm text-slate-500">
                Create your first event to start syncing attendees and scanning tickets.
              </p>

              <button
                type="button"
                phx-click="show_new_event_form"
                class="mt-6 rounded-md bg-blue-600 px-6 py-2 text-sm font-semibold text-white shadow hover:bg-blue-500"
              >
                Create event
              </button>
            </div>
          </div>
        </div>

        <div
          :if={@editing_event_id}
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
          phx-click="hide_edit_form"
          phx-key="Escape"
        >
          <div
            class="w-full max-w-2xl rounded-2xl bg-white p-8 shadow-xl"
            phx-click-away="hide_edit_form"
          >
            <div class="mb-6 flex items-center justify-between">
              <h2 class="text-2xl font-semibold text-slate-900">Edit Event</h2>

              <button
                type="button"
                phx-click="hide_edit_form"
                class="text-slate-400 hover:text-slate-600"
                aria-label="Close"
              >
                <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>

            <.form
              :if={@edit_form}
              for={@edit_form}
              phx-submit="update_event"
              class="space-y-4"
            >
              <.input
                field={@edit_form[:name]}
                type="text"
                label="Event Name"
                required
                class="w-full"
              />
              <.input
                field={@edit_form[:tickera_site_url]}
                type="url"
                label="Tickera Site URL"
                required
                class="w-full"
              />
              <.input
                field={@edit_form[:tickera_api_key_last4]}
                type="text"
                label="API Key (last 4)"
                disabled
                class="w-full"
              />
              <div class="rounded-lg bg-yellow-50 border border-yellow-200 p-4">
                <p class="text-sm text-yellow-800">
                  <strong>Note:</strong>
                  To update the API key, enter a new one below. Leave blank to keep current key.
                </p>

                <input
                  type="password"
                  name="event[tickera_api_key_encrypted]"
                  placeholder="Enter new API key (optional)"
                  class="mt-2 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                />
              </div>

              <.input
                field={@edit_form[:mobile_access_code]}
                type="password"
                label="Mobile Access Code"
                placeholder="Enter new code to change (optional)"
                class="w-full"
              />
              <.input
                field={@edit_form[:location]}
                type="text"
                label="Location"
                class="w-full"
              />
              <.input
                field={@edit_form[:entrance_name]}
                type="text"
                label="Entrance Name"
                class="w-full"
              />
              <div class="flex gap-3 pt-4">
                <button
                  type="submit"
                  class="flex-1 rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow hover:bg-blue-500"
                >
                  Save Changes
                </button>
                <button
                  type="button"
                  phx-click="hide_edit_form"
                  class="flex-1 rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </div>

        <div
          :if={@viewing_sync_history_for}
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
          phx-click="hide_sync_history"
          phx-key="Escape"
        >
          <div
            class="w-full max-w-3xl rounded-2xl bg-white p-8 shadow-xl max-h-[90vh] overflow-y-auto"
            phx-click-away="hide_sync_history"
          >
            <div class="mb-6 flex items-center justify-between">
              <h2 class="text-2xl font-semibold text-slate-900">Sync History</h2>

              <button
                type="button"
                phx-click="hide_sync_history"
                class="text-slate-400 hover:text-slate-600"
                aria-label="Close"
              >
                <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>

            <div :if={@sync_history == []} class="text-center py-8">
              <p class="text-slate-500">No sync history available for this event.</p>
            </div>

            <div :if={@sync_history != []} class="space-y-3">
              <%= for log <- @sync_history do %>
                <div class="rounded-lg border border-slate-200 p-4">
                  <div class="flex items-start justify-between">
                    <div class="flex-1">
                      <div class="flex items-center gap-2">
                        <span class={sync_status_badge_class(log.status)}>
                          {sync_status_label(log.status)}
                        </span>
                        <span class="text-sm text-slate-500">{format_datetime(log.started_at)}</span>
                      </div>

                      <div class="mt-2 grid grid-cols-2 gap-4 text-sm">
                        <div>
                          <span class="text-slate-500">Attendees synced:</span>
                          <span class="ml-2 font-semibold text-slate-900">
                            {log.attendees_synced || 0}
                          </span>
                        </div>

                        <div>
                          <span class="text-slate-500">Pages processed:</span>
                          <span class="ml-2 font-semibold text-slate-900">
                            {if log.total_pages,
                              do: "#{log.pages_processed || 0}/#{log.total_pages}",
                              else: "#{log.pages_processed || 0}"}
                          </span>
                        </div>

                        <div :if={log.duration_ms}>
                          <span class="text-slate-500">Duration:</span>
                          <span class="ml-2 font-semibold text-slate-900">
                            {format_duration(log.duration_ms)}
                          </span>
                        </div>

                        <div :if={log.completed_at}>
                          <span class="text-slate-500">Completed:</span>
                          <span class="ml-2 font-semibold text-slate-900">
                            {format_datetime(log.completed_at)}
                          </span>
                        </div>
                      </div>

                      <p :if={log.error_message} class="mt-2 text-sm text-red-600">
                        Error: {log.error_message}
                      </p>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp empty_event_form do
    %Event{}
    |> Event.changeset(%{})
    |> to_form()
  end

  defp sticky_event_form(params) do
    %Event{}
    |> Event.changeset(params)
    |> to_form()
  end

  defp build_edit_form(%Event{} = event) do
    # Build form with current event values, excluding encrypted fields
    attrs = %{
      "name" => event.name,
      "tickera_site_url" => event.tickera_site_url,
      "tickera_api_key_last4" => event.tickera_api_key_last4,
      "location" => event.location,
      "entrance_name" => event.entrance_name,
      # Don't show existing secret
      "mobile_access_code" => ""
    }

    event
    |> Event.changeset(attrs)
    |> to_form()
  end

  defp parse_event_id(event_id) when is_integer(event_id), do: {:ok, event_id}

  defp parse_event_id(event_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {value, _} -> {:ok, value}
      :error -> {:error, "Invalid event identifier"}
    end
  end

  defp parse_event_id(_), do: {:error, "Invalid event identifier"}

  defp start_sync_task(event_id, opts) do
    parent = self()
    incremental = Keyword.get(opts, :incremental, false)

    Task.start_link(fn ->
      result =
        Events.sync_event(
          event_id,
          fn page, total, count ->
            send(parent, {:sync_progress, page, total, count})
          end,
          incremental: incremental
        )

      if match?({:error, _}, result) do
        {:error, reason} = result
        send(parent, {:sync_error, format_error(reason)})
      end

      send(parent, :sync_complete)
    end)
  end

  defp progress_status(page, total, count, estimated_remaining) do
    base_status =
      cond do
        total in [nil, 0] -> "Syncing attendees..."
        true -> "Syncing attendees (page #{page}/#{total}) • Imported #{count} records"
      end

    if estimated_remaining && estimated_remaining > 0 do
      time_str = format_time_estimate(estimated_remaining)
      "#{base_status} • Estimated time remaining: #{time_str}"
    else
      base_status
    end
  end

  defp calculate_avg_time_per_page([], _current_page), do: nil
  defp calculate_avg_time_per_page([%{page: 1}], _current_page), do: nil

  defp calculate_avg_time_per_page(timing_data, current_page) when current_page > 1 do
    # Calculate time differences between pages
    times =
      timing_data
      |> Enum.sort_by(& &1.page)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] -> curr.elapsed - prev.elapsed end)
      |> Enum.filter(&(&1 > 0))

    if length(times) > 0 do
      times
      |> Enum.sum()
      |> Kernel./(length(times))
    else
      nil
    end
  end

  defp calculate_avg_time_per_page(_, _), do: nil

  defp format_time_estimate(seconds) when seconds < 60 do
    "#{seconds}s"
  end

  defp format_time_estimate(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    if remaining_seconds > 0 do
      "#{minutes}m #{remaining_seconds}s"
    else
      "#{minutes}m"
    end
  end

  defp format_time_estimate(seconds) do
    hours = div(seconds, 3600)
    remaining_minutes = div(rem(seconds, 3600), 60)

    if remaining_minutes > 0 do
      "#{hours}h #{remaining_minutes}m"
    else
      "#{hours}h"
    end
  end

  defp progress_percent(nil), do: 0

  defp progress_percent({page, total, _count}) when is_integer(total) and total > 0 do
    page
    |> Kernel./(total)
    |> Kernel.*(100.0)
    |> min(100.0)
  end

  defp progress_percent(_), do: 0

  defp progress_details(nil), do: "Awaiting sync progress..."

  defp progress_details({page, total, count}) do
    safe_total = total || 1

    ["Page #{page} of #{max(safe_total, 1)}", "#{count} attendees processed"]
    |> Enum.join(" · ")
  end

  defp lifecycle_badge_class(:archived), do: "bg-red-100 text-red-700"
  defp lifecycle_badge_class(:grace), do: "bg-amber-100 text-amber-700"
  defp lifecycle_badge_class(:upcoming), do: "bg-slate-100 text-slate-700"
  defp lifecycle_badge_class(:unknown), do: "bg-slate-100 text-slate-700"
  defp lifecycle_badge_class(_), do: "bg-emerald-100 text-emerald-700"

  defp lifecycle_label(:archived), do: "Archived"
  defp lifecycle_label(:grace), do: "In grace period"
  defp lifecycle_label(:upcoming), do: "Upcoming"
  defp lifecycle_label(:unknown), do: "Status unknown"
  defp lifecycle_label(_), do: "Active"

  defp format_error(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} ->
      "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}"
    end)
    |> Enum.join(". ")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp filter_events(events, query) when is_binary(query) do
    trimmed = String.trim(query) |> String.downcase()

    if trimmed == "" do
      events
    else
      Enum.filter(events, fn event ->
        name_match = event.name && String.contains?(String.downcase(event.name), trimmed)

        location_match =
          event.location && String.contains?(String.downcase(event.location), trimmed)

        entrance_match =
          event.entrance_name && String.contains?(String.downcase(event.entrance_name), trimmed)

        status_match = event.status && String.contains?(String.downcase(event.status), trimmed)

        name_match || location_match || entrance_match || status_match
      end)
    end
  end

  defp filter_events(events, _), do: events

  defp sync_status_badge_class("completed"),
    do: "rounded-full bg-green-100 px-3 py-1 text-xs font-semibold text-green-700"

  defp sync_status_badge_class("failed"),
    do: "rounded-full bg-red-100 px-3 py-1 text-xs font-semibold text-red-700"

  defp sync_status_badge_class("in_progress"),
    do: "rounded-full bg-blue-100 px-3 py-1 text-xs font-semibold text-blue-700"

  defp sync_status_badge_class("paused"),
    do: "rounded-full bg-yellow-100 px-3 py-1 text-xs font-semibold text-yellow-700"

  defp sync_status_badge_class("cancelled"),
    do: "rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700"

  defp sync_status_badge_class(_),
    do: "rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700"

  defp sync_status_label("completed"), do: "Completed"
  defp sync_status_label("failed"), do: "Failed"
  defp sync_status_label("in_progress"), do: "In Progress"
  defp sync_status_label("paused"), do: "Paused"
  defp sync_status_label("cancelled"), do: "Cancelled"
  defp sync_status_label(_), do: "Unknown"

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(_), do: "—"

  defp format_duration(nil), do: "—"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 ->
        "#{seconds}s"

      seconds < 3600 ->
        minutes = div(seconds, 60)
        remaining_seconds = rem(seconds, 60)

        if remaining_seconds > 0 do
          "#{minutes}m #{remaining_seconds}s"
        else
          "#{minutes}m"
        end

      true ->
        hours = div(seconds, 3600)
        remaining_minutes = div(rem(seconds, 3600), 60)

        if remaining_minutes > 0 do
          "#{hours}h #{remaining_minutes}m"
        else
          "#{hours}h"
        end
    end
  end

  defp format_duration(_), do: "—"
end
