defmodule FastCheckWeb.DashboardLive do
  @moduledoc """
  Admin dashboard for managing events, launching attendee syncs, and
  monitoring high-level statistics.
  """

  use FastCheckWeb, :live_view

  alias Ecto.Changeset
  alias FastCheck.Events
  alias FastCheck.Events.Event
  alias Phoenix.LiveView.JS

  @max_sync_attempts 3
  @sync_attempt_timeout_ms 120_000

  @impl true
  def mount(_params, _session, socket) do
    events = Events.list_events()

    {:ok,
     socket
     |> assign(:events, events)
     |> assign(:filtered_events, events)
     |> assign(:events_tab, "active")
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
     |> assign(:sync_task_ref, nil)
     |> assign(:sync_run_ref, nil)
     |> assign(:sync_attempt, nil)
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
      {:ok, _event} ->
        refreshed_events = Events.list_events()

        {:noreply,
         socket
         |> assign(:events, refreshed_events)
         |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
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
    socket = clear_stale_sync_runtime(socket)

    if sync_task_running?(socket) do
      {:noreply, assign(socket, :sync_status, "A sync is already running for this dashboard")}
    else
      with {:ok, event_id} <- parse_event_id(event_id_param),
           {:ok, task_meta} <- start_sync_task(event_id, incremental: incremental) do
        start_time = System.monotonic_time(:second)
        sync_type = if incremental, do: "incremental", else: "full"

        {:noreply,
         socket
         |> assign(:selected_event_id, event_id)
         |> assign(:sync_progress, {0, 0, 0})
         |> assign(:sync_start_time, start_time)
         |> assign(:sync_timing_data, [])
         |> assign(:sync_paused, false)
         |> assign(:sync_task_pid, task_meta.pid)
         |> assign(:sync_task_ref, task_meta.monitor_ref)
         |> assign(:sync_run_ref, task_meta.run_ref)
         |> assign(:sync_attempt, 1)
         |> assign(
           :sync_status,
           "Starting #{sync_type} attendee sync (attempt 1/#{@max_sync_attempts})..."
         )}
      else
        {:error, reason} ->
          {:noreply, assign(socket, :sync_status, reason)}
      end
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
  def handle_event("switch_events_tab", %{"tab" => tab}, socket)
      when tab in ["active", "archived"] do
    {:noreply, assign(socket, :events_tab, tab)}
  end

  def handle_event("switch_events_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("archive_event", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, _event} <- Events.archive_event(event_id) do
      refreshed_events = Events.list_events()

      {:noreply,
       socket
       |> assign(:events, refreshed_events)
       |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
       |> assign(:selected_event_id, nil)
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
       |> assign(:events_tab, "active")
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
      Events.force_reset_sync(event_id, :cancelled)

      if is_pid(socket.assigns.sync_task_pid) and Process.alive?(socket.assigns.sync_task_pid) do
        Process.exit(socket.assigns.sync_task_pid, :kill)
      end

      refreshed_events = Events.list_events()

      {:noreply,
       socket
       |> maybe_demonitor_sync_task()
       |> assign(:events, refreshed_events)
       |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
       |> reset_sync_runtime()
       |> assign(:sync_status, "Sync cancelled")
       |> assign(:selected_event_id, nil)}
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
  def handle_info({:sync_progress, run_ref, page, total, count}, socket)
      when run_ref == socket.assigns.sync_run_ref do
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
  def handle_info({:sync_progress, _run_ref, _page, _total, _count}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_retry, run_ref, attempt, max_attempts, reason}, socket)
      when run_ref == socket.assigns.sync_run_ref do
    next_attempt = min(attempt + 1, max_attempts)

    {:noreply,
     socket
     |> assign(:sync_attempt, next_attempt)
     |> assign(
       :sync_status,
       "Sync attempt #{attempt}/#{max_attempts} failed (#{reason}). Retrying attempt #{next_attempt}/#{max_attempts}..."
     )}
  end

  @impl true
  def handle_info({:sync_retry, _run_ref, _attempt, _max_attempts, _reason}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_error, run_ref, message}, socket)
      when run_ref == socket.assigns.sync_run_ref do
    refreshed_events = Events.list_events()

    {:noreply,
     socket
     |> maybe_demonitor_sync_task()
     |> assign(:events, refreshed_events)
     |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
     |> reset_sync_runtime()
     |> assign(:sync_status, "Sync failed: #{message}")
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def handle_info({:sync_error, _run_ref, _message}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_error, message}, socket) do
    refreshed_events = Events.list_events()

    {:noreply,
     socket
     |> maybe_demonitor_sync_task()
     |> assign(:events, refreshed_events)
     |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
     |> reset_sync_runtime()
     |> assign(:sync_status, "Sync failed: #{message}")
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def handle_info({:sync_complete, run_ref}, socket)
      when run_ref == socket.assigns.sync_run_ref do
    refreshed_events = Events.list_events()

    final_status =
      case socket.assigns.sync_status do
        nil -> "Sync complete!"
        "Sync failed" <> _rest -> socket.assigns.sync_status
        _ -> "Sync complete!"
      end

    {:noreply,
     socket
     |> maybe_demonitor_sync_task()
     |> assign(:events, refreshed_events)
     |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
     |> reset_sync_runtime()
     |> assign(:sync_status, final_status)
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def handle_info({:sync_complete, _run_ref}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:sync_complete, socket) do
    refreshed_events = Events.list_events()

    {:noreply,
     socket
     |> maybe_demonitor_sync_task()
     |> assign(:events, refreshed_events)
     |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
     |> reset_sync_runtime()
     |> assign(:sync_status, "Sync complete!")
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when ref == socket.assigns.sync_task_ref do
    refreshed_events = Events.list_events()
    selected_event_id = socket.assigns.selected_event_id

    status_message =
      case reason do
        :normal ->
          socket.assigns.sync_status || "Sync complete!"

        _ ->
          if is_integer(selected_event_id) do
            Events.force_reset_sync(selected_event_id, {:worker_exit, reason})
          end

          "Sync failed: worker exited unexpectedly (#{inspect(reason)})"
      end

    {:noreply,
     socket
     |> assign(:events, refreshed_events)
     |> assign(:filtered_events, filter_events(refreshed_events, socket.assigns.search_query))
     |> reset_sync_runtime()
     |> assign(:sync_status, status_message)
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def render(assigns) do
    visible_events = events_for_tab(assigns.filtered_events, assigns.events_tab)
    active_events_count = count_events_for_tab(assigns.filtered_events, "active")
    archived_events_count = count_events_for_tab(assigns.filtered_events, "archived")

    assigns =
      assigns
      |> assign(:search_form, to_form(%{"query" => assigns.search_query}))
      |> assign(:visible_events, visible_events)
      |> assign(:active_events_count, active_events_count)
      |> assign(:archived_events_count, archived_events_count)

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6 sm:space-y-8">
        <section class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p
              style="font-size: var(--fc-text-xs)"
              class="uppercase tracking-[0.35em] text-fc-text-muted"
            >
              Control center
            </p>
            <h1 style="font-size: var(--fc-text-3xl)" class="mt-2 font-semibold text-fc-text-primary">
              FastCheck dashboard
            </h1>
          </div>

          <.button
            id="show-new-event-form-button"
            type="button"
            phx-click="show_new_event_form"
            color="primary"
            variant="shadow"
          >
            New Event
          </.button>
        </section>

        <.card :if={@sync_status} variant="outline" color="natural" rounded="large" padding="large">
          <.card_content>
            <p class="text-sm text-fc-text-secondary">Sync status</p>
            <p class="mt-1 text-base font-semibold text-fc-text-primary">{@sync_status}</p>

            <div :if={@sync_progress} class="mt-4 space-y-2">
              <.progress
                value={trunc(progress_percent(@sync_progress))}
                color="secondary"
                size="small"
              />
              <p class="text-xs text-fc-text-muted">{progress_details(@sync_progress)}</p>
            </div>
          </.card_content>
        </.card>

        <.card
          :if={@show_new_event_form}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
        >
          <.card_content>
            <div class="flex items-center justify-between gap-3">
              <div>
                <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
                  Create new event
                </h2>
                <p class="mt-1 text-sm text-fc-text-secondary">
                  Connect a Tickera event and define entrance settings.
                </p>
              </div>

              <.button
                id="hide-new-event-form-button"
                type="button"
                phx-click="hide_new_event_form"
                variant="bordered"
                color="natural"
                size="small"
              >
                Cancel
              </.button>
            </div>

            <.form
              id="create-event-form"
              for={@form}
              phx-submit="create_event"
              class="mt-6 grid grid-cols-1 gap-5 md:grid-cols-2"
            >
              <.input
                field={@form[:name]}
                type="text"
                label="Event name"
                placeholder="Tech Summit 2026"
              />
              <.input
                field={@form[:tickera_site_url]}
                type="url"
                label="Site URL"
                placeholder="https://example.com"
              />

              <.input
                field={@form[:tickera_api_key_encrypted]}
                type="password"
                label="Tickera API key"
                placeholder="Paste API key"
              />

              <.input
                field={@form[:mobile_access_code]}
                type="password"
                label="Mobile access code"
                placeholder="Required for scanner login"
                required
              />
              <p class="md:col-span-2 -mt-3 text-xs text-fc-text-muted">
                Scanner login uses a 6-character event code + mobile access code + operator name.
              </p>

              <.input field={@form[:location]} type="text" label="Location" placeholder="Main venue" />
              <.input
                field={@form[:entrance_name]}
                type="text"
                label="Entrance name"
                placeholder="Main gate"
              />

              <div class="md:col-span-2 flex flex-wrap items-center gap-3">
                <.button
                  id="create-event-button"
                  type="submit"
                  color="primary"
                  variant="shadow"
                  phx-disable-with="Creating..."
                >
                  Create event
                </.button>

                <.button
                  id="cancel-create-event-button"
                  type="button"
                  phx-click="hide_new_event_form"
                  variant="bordered"
                  color="natural"
                >
                  Nevermind
                </.button>
              </div>
            </.form>
          </.card_content>
        </.card>

        <section class="space-y-4">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
                Events
              </h2>
              <p class="text-sm text-fc-text-secondary">
                Manage syncs, scanners, and lifecycle state.
              </p>
            </div>

            <div class="w-full sm:max-w-md">
              <.form
                id="event-search-form"
                for={@search_form}
                phx-change="search_events"
                class="relative"
              >
                <.input
                  field={@search_form[:query]}
                  type="search"
                  placeholder="Search events by name or location"
                  phx-debounce="300"
                />

                <.button
                  :if={@search_query != ""}
                  id="clear-event-search-button"
                  type="button"
                  phx-click="search_events"
                  phx-value-query=""
                  variant="transparent"
                  color="natural"
                  size="extra_small"
                  class="absolute right-2 top-8"
                >
                  Clear
                </.button>
              </.form>
            </div>
          </div>

          <div class="inline-flex w-full sm:w-auto rounded-xl border border-fc-border bg-fc-surface-overlay p-1">
            <.button
              id="events-tab-active"
              type="button"
              phx-click="switch_events_tab"
              phx-value-tab="active"
              color={if(@events_tab == "active", do: "primary", else: "natural")}
              variant={if(@events_tab == "active", do: "shadow", else: "transparent")}
              size="small"
              class="flex-1 sm:flex-none"
            >
              Active ({@active_events_count})
            </.button>

            <.button
              id="events-tab-archived"
              type="button"
              phx-click="switch_events_tab"
              phx-value-tab="archived"
              color={if(@events_tab == "archived", do: "primary", else: "natural")}
              variant={if(@events_tab == "archived", do: "shadow", else: "transparent")}
              size="small"
              class="flex-1 sm:flex-none"
            >
              Archived ({@archived_events_count})
            </.button>
          </div>

          <div class="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
            <.card
              :for={event <- @visible_events}
              variant="outline"
              color="natural"
              rounded="large"
              padding="large"
              class={"fc-card-container #{if(@selected_event_id == event.id, do: "ring-2 ring-primary-light", else: "")}"}
            >
              <.card_content>
                <% lifecycle_state = Events.event_lifecycle_state(event) %>
                <% archived_event = archived_event?(event) %>

                <div class="flex items-start justify-between gap-3">
                  <div>
                    <p
                      style="font-size: var(--fc-text-xs)"
                      class="uppercase tracking-[0.35em] text-fc-text-muted"
                    >
                      {event.location || "Unassigned"}
                    </p>
                    <h3 class="mt-2 text-xl font-semibold text-fc-text-primary">{event.name}</h3>
                    <p class="mt-1 text-xs text-fc-text-muted">Event ID {event.id}</p>
                    <p class="mt-1 text-xs text-fc-text-muted">
                      Scanner code {event.scanner_login_code || "Unavailable"}
                    </p>
                  </div>

                  <div class="flex flex-col items-end gap-2">
                    <.badge color="secondary" variant="bordered" rounded="full" size="extra_small">
                      {event.entrance_name || "Entrance"}
                    </.badge>
                    <.badge
                      color={lifecycle_badge_color(lifecycle_state)}
                      variant="bordered"
                      rounded="full"
                      size="extra_small"
                    >
                      {lifecycle_label(lifecycle_state)}
                    </.badge>
                  </div>
                </div>

                <div class="mt-5 grid gap-3 cq-card:grid-cols-3 text-center">
                  <div class="rounded-xl bg-fc-surface-overlay px-3 py-3">
                    <p class="text-xs uppercase tracking-[0.3em] text-fc-text-muted">Total tickets</p>
                    <p class="mt-1 text-xl font-semibold text-fc-text-primary">
                      {event.total_tickets || 0}
                    </p>
                  </div>

                  <div class="rounded-xl bg-fc-surface-overlay px-3 py-3">
                    <p class="text-xs uppercase tracking-[0.3em] text-fc-text-muted">Checked in</p>
                    <p class="mt-1 text-xl font-semibold text-fc-text-primary">
                      {event.checked_in_count || 0}
                    </p>
                  </div>

                  <div class="rounded-xl bg-fc-surface-overlay px-3 py-3">
                    <p class="text-xs uppercase tracking-[0.3em] text-fc-text-muted">Attendees</p>
                    <p class="mt-1 text-xl font-semibold text-fc-text-primary">
                      {event.attendee_count || 0}
                    </p>
                  </div>
                </div>

                <div class="mt-6 space-y-3">
                  <div :if={!archived_event} class="space-y-3">
                    <div
                      :if={@selected_event_id != event.id || @sync_progress == nil}
                      class="grid gap-2 cq-card:grid-cols-2"
                    >
                      <.button
                        id={"full-sync-#{event.id}"}
                        type="button"
                        color="secondary"
                        variant="shadow"
                        full_width
                        phx-click="start_sync"
                        phx-value-event_id={event.id}
                        phx-value-incremental="false"
                        phx-disable-with="Syncing..."
                        disabled={lifecycle_state == :archived || !is_nil(@sync_task_pid)}
                      >
                        Full sync
                      </.button>

                      <.button
                        id={"incremental-sync-#{event.id}"}
                        type="button"
                        color="success"
                        variant="shadow"
                        full_width
                        phx-click="start_sync"
                        phx-value-event_id={event.id}
                        phx-value-incremental="true"
                        phx-disable-with="Syncing..."
                        disabled={lifecycle_state == :archived || !is_nil(@sync_task_pid)}
                        title="Only sync new or updated attendees"
                      >
                        Incremental sync
                      </.button>
                    </div>

                    <div
                      :if={@selected_event_id == event.id && @sync_progress != nil}
                      class="grid gap-2 cq-card:grid-cols-3"
                    >
                      <.button
                        :if={!@sync_paused}
                        id={"pause-sync-#{event.id}"}
                        type="button"
                        phx-click="pause_sync"
                        phx-value-event_id={event.id}
                        color="warning"
                        variant="shadow"
                        full_width
                      >
                        Pause
                      </.button>

                      <.button
                        :if={@sync_paused}
                        id={"resume-sync-#{event.id}"}
                        type="button"
                        phx-click="resume_sync"
                        phx-value-event_id={event.id}
                        color="success"
                        variant="shadow"
                        full_width
                      >
                        Resume
                      </.button>

                      <.button
                        id={"cancel-sync-#{event.id}"}
                        type="button"
                        phx-click="cancel_sync"
                        phx-value-event_id={event.id}
                        color="danger"
                        variant="shadow"
                        full_width
                      >
                        Cancel
                      </.button>
                    </div>

                    <div class="grid gap-2 cq-card:grid-cols-2">
                      <.button_link
                        navigate={~p"/scan/#{event.id}"}
                        variant="bordered"
                        color="secondary"
                        full_width
                      >
                        Open scanner
                      </.button_link>

                      <.button
                        id={"show-sync-history-#{event.id}"}
                        type="button"
                        phx-click="show_sync_history"
                        phx-value-event_id={event.id}
                        variant="bordered"
                        color="natural"
                        full_width
                      >
                        Sync history
                      </.button>
                    </div>

                    <.button
                      id={"show-edit-event-#{event.id}"}
                      type="button"
                      phx-click="show_edit_form"
                      phx-value-event_id={event.id}
                      variant="bordered"
                      color="secondary"
                      full_width
                    >
                      Edit event
                    </.button>

                    <div class="grid gap-2 cq-card:grid-cols-2">
                      <.button_link
                        href={~p"/export/attendees/#{event.id}"}
                        variant="bordered"
                        color="success"
                        full_width
                      >
                        Export attendees
                      </.button_link>

                      <.button_link
                        href={~p"/export/check-ins/#{event.id}"}
                        variant="bordered"
                        color="success"
                        full_width
                      >
                        Export check-ins
                      </.button_link>
                    </div>

                    <.button
                      id={"archive-event-#{event.id}"}
                      type="button"
                      phx-click="archive_event"
                      phx-value-event_id={event.id}
                      variant="bordered"
                      color="danger"
                      full_width
                      data-confirm="Archive this event? Archived events cannot be synced or scanned."
                    >
                      Archive event
                    </.button>
                  </div>

                  <div :if={archived_event} class="space-y-2">
                    <.button
                      id={"unarchive-event-#{event.id}"}
                      type="button"
                      phx-click="unarchive_event"
                      phx-value-event_id={event.id}
                      variant="bordered"
                      color="success"
                      full_width
                    >
                      Unarchive event
                    </.button>

                    <p class="text-xs text-danger-light dark:text-danger-dark">
                      This event is archived. Unarchive to restore sync and scanner access.
                    </p>
                  </div>
                </div>
              </.card_content>
            </.card>

            <.card
              :if={Enum.empty?(@visible_events) && @search_query != ""}
              variant="outline"
              color="natural"
              rounded="large"
              padding="large"
              class="col-span-full text-center"
            >
              <.card_content>
                <p class="text-lg font-semibold text-fc-text-primary">No events found</p>
                <p class="mt-2 text-sm text-fc-text-secondary">No events match "{@search_query}".</p>
              </.card_content>
            </.card>

            <.card
              :if={Enum.empty?(@visible_events) && @search_query == ""}
              variant="outline"
              color="natural"
              rounded="large"
              padding="large"
              class="col-span-full text-center"
            >
              <.card_content>
                <%= if @events_tab == "active" do %>
                  <p class="text-lg font-semibold text-fc-text-primary">No active events</p>
                  <p class="mt-2 text-sm text-fc-text-secondary">
                    Create your first event to start syncing attendees and scanning tickets.
                  </p>
                  <.button
                    id="empty-state-create-event-button"
                    type="button"
                    phx-click="show_new_event_form"
                    color="primary"
                    variant="shadow"
                    class="mt-5"
                  >
                    Create event
                  </.button>
                <% else %>
                  <p class="text-lg font-semibold text-fc-text-primary">No archived events</p>
                  <p class="mt-2 text-sm text-fc-text-secondary">
                    Archived events will appear here and can be restored with one click.
                  </p>
                <% end %>
              </.card_content>
            </.card>
          </div>
        </section>

        <.modal
          id="edit-event-modal"
          title="Edit Event"
          show={@editing_event_id != nil}
          size="double_large"
          rounded="large"
          color="natural"
          on_cancel={JS.push("hide_edit_form")}
        >
          <p :if={@editing_event_id} class="text-sm text-fc-text-secondary">
            Event ID {@editing_event_id}
          </p>
          <p :if={@edit_form} class="text-sm text-fc-text-secondary">
            Scanner code {@edit_form[:scanner_login_code].value || "Unavailable"}
          </p>

          <.form
            :if={@edit_form}
            id="edit-event-form"
            for={@edit_form}
            phx-submit="update_event"
            class="space-y-4"
          >
            <.input field={@edit_form[:name]} type="text" label="Event name" required />
            <.input
              field={@edit_form[:tickera_site_url]}
              type="url"
              label="Tickera site URL"
              required
            />

            <.input
              field={@edit_form[:tickera_api_key_last4]}
              type="text"
              label="API key (last 4)"
              disabled
            />

            <.input
              field={@edit_form[:scanner_login_code]}
              type="text"
              label="Scanner event code"
              disabled
            />

            <.card variant="bordered" color="warning" rounded="large" padding="medium">
              <.card_content>
                <p class="text-sm">
                  To rotate the API key, provide a new one. Leave empty to keep the current key.
                </p>
                <.input
                  id="edit-event-new-api-key"
                  name="event[tickera_api_key_encrypted]"
                  type="password"
                  label="New API key (optional)"
                  value=""
                  autocomplete="new-password"
                />
              </.card_content>
            </.card>

            <.input
              field={@edit_form[:mobile_access_code]}
              type="password"
              label="Mobile access code"
              placeholder="Enter new code to change"
            />
            <p class="-mt-3 text-xs text-fc-text-muted">
              Leave blank to keep the current scanner login code.
            </p>

            <.input field={@edit_form[:location]} type="text" label="Location" />
            <.input field={@edit_form[:entrance_name]} type="text" label="Entrance name" />

            <div class="pt-3 grid gap-2 sm:grid-cols-2">
              <.button
                id="save-event-button"
                type="submit"
                color="primary"
                variant="shadow"
                full_width
              >
                Save changes
              </.button>

              <.button
                id="cancel-edit-event-button"
                type="button"
                phx-click="hide_edit_form"
                variant="bordered"
                color="natural"
                full_width
              >
                Cancel
              </.button>
            </div>
          </.form>
        </.modal>

        <.modal
          id="sync-history-modal"
          title="Sync History"
          show={@viewing_sync_history_for != nil}
          size="triple_large"
          rounded="large"
          color="natural"
          on_cancel={JS.push("hide_sync_history")}
        >
          <div :if={@sync_history == []} class="py-8 text-center text-fc-text-secondary">
            No sync history available for this event.
          </div>

          <div :if={@sync_history != []} class="space-y-3">
            <.card
              :for={log <- @sync_history}
              variant="outline"
              color="natural"
              rounded="large"
              padding="medium"
            >
              <.card_content>
                <div class="flex flex-wrap items-center gap-2">
                  <.badge
                    color={sync_status_badge_color(log.status)}
                    variant="bordered"
                    rounded="full"
                  >
                    {sync_status_label(log.status)}
                  </.badge>
                  <span class="text-sm text-fc-text-secondary">
                    {format_datetime(log.started_at)}
                  </span>
                </div>

                <div class="mt-3 grid gap-2 cq-card:grid-cols-2 text-sm">
                  <p class="text-fc-text-secondary">
                    Attendees synced:
                    <span class="font-semibold text-fc-text-primary">
                      {log.attendees_synced || 0}
                    </span>
                  </p>
                  <p class="text-fc-text-secondary">
                    Pages processed:
                    <span class="font-semibold text-fc-text-primary">
                      {if log.total_pages,
                        do: "#{log.pages_processed || 0}/#{log.total_pages}",
                        else: "#{log.pages_processed || 0}"}
                    </span>
                  </p>

                  <p :if={log.duration_ms} class="text-fc-text-secondary">
                    Duration:
                    <span class="font-semibold text-fc-text-primary">
                      {format_duration(log.duration_ms)}
                    </span>
                  </p>

                  <p :if={log.completed_at} class="text-fc-text-secondary">
                    Completed:
                    <span class="font-semibold text-fc-text-primary">
                      {format_datetime(log.completed_at)}
                    </span>
                  </p>
                </div>

                <p
                  :if={log.error_message}
                  class="mt-2 text-sm text-danger-light dark:text-danger-dark"
                >
                  Error: {log.error_message}
                </p>
              </.card_content>
            </.card>
          </div>
        </.modal>
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
      "scanner_login_code" => event.scanner_login_code,
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
    max_attempts = Keyword.get(opts, :max_attempts, @max_sync_attempts)
    attempt_timeout_ms = Keyword.get(opts, :attempt_timeout_ms, @sync_attempt_timeout_ms)
    run_ref = make_ref()

    case Task.start(fn ->
           run_sync_with_retries(
             parent,
             run_ref,
             event_id,
             incremental,
             max_attempts,
             attempt_timeout_ms
           )
         end) do
      {:ok, pid} ->
        {:ok, %{pid: pid, monitor_ref: Process.monitor(pid), run_ref: run_ref}}

      error ->
        error
    end
  end

  defp run_sync_with_retries(
         parent,
         run_ref,
         event_id,
         incremental,
         max_attempts,
         attempt_timeout_ms
       ) do
    do_run_sync_attempt(
      parent,
      run_ref,
      event_id,
      incremental,
      1,
      max_attempts,
      attempt_timeout_ms
    )
  rescue
    exception ->
      Events.force_reset_sync(event_id, {:retry_worker_exception, exception})
      send(parent, {:sync_error, run_ref, "Sync worker crashed: #{Exception.message(exception)}"})
      send(parent, {:sync_complete, run_ref})
  catch
    kind, reason ->
      Events.force_reset_sync(event_id, {:retry_worker_throw, {kind, reason}})
      send(parent, {:sync_error, run_ref, "Sync worker crashed: #{inspect({kind, reason})}"})
      send(parent, {:sync_complete, run_ref})
  end

  defp do_run_sync_attempt(
         parent,
         run_ref,
         event_id,
         incremental,
         attempt,
         max_attempts,
         attempt_timeout_ms
       ) do
    case run_sync_attempt(event_id, incremental, parent, run_ref, attempt_timeout_ms) do
      {:ok, _message} ->
        send(parent, {:sync_complete, run_ref})

      {:error, reason} when attempt < max_attempts ->
        Events.force_reset_sync(event_id, {:retrying_after_error, reason})

        send(
          parent,
          {:sync_retry, run_ref, attempt, max_attempts, shorten_reason(format_error(reason))}
        )

        do_run_sync_attempt(
          parent,
          run_ref,
          event_id,
          incremental,
          attempt + 1,
          max_attempts,
          attempt_timeout_ms
        )

      {:error, reason} ->
        Events.force_reset_sync(event_id, {:final_failure, reason})

        send(
          parent,
          {:sync_error, run_ref,
           "Failed to sync after #{max_attempts} attempts: #{shorten_reason(format_error(reason))}"}
        )

        send(parent, {:sync_complete, run_ref})
    end
  end

  defp run_sync_attempt(event_id, incremental, parent, run_ref, attempt_timeout_ms) do
    caller = self()
    attempt_ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        result =
          try do
            Events.sync_event(
              event_id,
              fn page, total, count ->
                send(caller, {:attempt_progress, attempt_ref, page, total, count})
              end,
              incremental: incremental
            )
          rescue
            exception -> {:error, Exception.message(exception)}
          catch
            :throw, {:sync_cancelled, ^event_id} -> {:error, "Sync cancelled"}
            kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
          end

        send(caller, {:attempt_result, attempt_ref, result})
      end)

    monitor_ref = Process.monitor(pid)
    await_sync_attempt_result(parent, run_ref, pid, monitor_ref, attempt_ref, attempt_timeout_ms)
  end

  defp await_sync_attempt_result(
         parent,
         run_ref,
         pid,
         monitor_ref,
         attempt_ref,
         attempt_timeout_ms
       ) do
    receive do
      {:attempt_progress, ^attempt_ref, page, total, count} ->
        send(parent, {:sync_progress, run_ref, page, total, count})

        await_sync_attempt_result(
          parent,
          run_ref,
          pid,
          monitor_ref,
          attempt_ref,
          attempt_timeout_ms
        )

      {:attempt_progress, _other_attempt_ref, _page, _total, _count} ->
        await_sync_attempt_result(
          parent,
          run_ref,
          pid,
          monitor_ref,
          attempt_ref,
          attempt_timeout_ms
        )

      {:attempt_result, ^attempt_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:attempt_result, _other_attempt_ref, _result} ->
        await_sync_attempt_result(
          parent,
          run_ref,
          pid,
          monitor_ref,
          attempt_ref,
          attempt_timeout_ms
        )

      {:DOWN, ^monitor_ref, :process, _attempt_pid, reason} ->
        {:error, "Sync worker exited: #{inspect(reason)}"}

      {:DOWN, _other_monitor_ref, :process, _attempt_pid, _reason} ->
        await_sync_attempt_result(
          parent,
          run_ref,
          pid,
          monitor_ref,
          attempt_ref,
          attempt_timeout_ms
        )
    after
      attempt_timeout_ms ->
        Process.exit(pid, :kill)
        {:error, "Sync attempt timed out after #{div(attempt_timeout_ms, 1000)}s"}
    end
  end

  defp clear_stale_sync_runtime(socket) do
    if sync_task_running?(socket) do
      socket
    else
      socket
      |> maybe_demonitor_sync_task()
      |> reset_sync_runtime()
    end
  end

  defp sync_task_running?(socket) do
    case socket.assigns.sync_task_pid do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp maybe_demonitor_sync_task(socket) do
    case Map.get(socket.assigns, :sync_task_ref) do
      ref when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        socket

      _ ->
        socket
    end
  end

  defp reset_sync_runtime(socket) do
    socket
    |> assign(:sync_progress, nil)
    |> assign(:sync_start_time, nil)
    |> assign(:sync_timing_data, [])
    |> assign(:sync_paused, false)
    |> assign(:sync_task_pid, nil)
    |> assign(:sync_task_ref, nil)
    |> assign(:sync_run_ref, nil)
    |> assign(:sync_attempt, nil)
  end

  defp shorten_reason(reason) when is_binary(reason) do
    if String.length(reason) > 220 do
      String.slice(reason, 0, 220) <> "..."
    else
      reason
    end
  end

  defp shorten_reason(reason), do: format_error(reason)

  defp progress_status(page, total, count, estimated_remaining) do
    base_status =
      cond do
        total in [nil, 0] -> "Syncing attendees..."
        true -> "Syncing attendees (page #{page}/#{total}) - Imported #{count} records"
      end

    if estimated_remaining && estimated_remaining > 0 do
      time_str = format_time_estimate(estimated_remaining)
      "#{base_status} - Estimated time remaining: #{time_str}"
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
    |> Enum.join(" - ")
  end

  defp lifecycle_badge_color(:archived), do: "danger"
  defp lifecycle_badge_color(:grace), do: "warning"
  defp lifecycle_badge_color(:upcoming), do: "natural"
  defp lifecycle_badge_color(:unknown), do: "natural"
  defp lifecycle_badge_color(_), do: "success"

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

  defp events_for_tab(events, "archived"), do: Enum.filter(events, &archived_event?/1)
  defp events_for_tab(events, _tab), do: Enum.reject(events, &archived_event?/1)

  defp count_events_for_tab(events, tab) do
    events
    |> events_for_tab(tab)
    |> length()
  end

  defp archived_event?(%Event{status: status}) when is_binary(status) do
    String.downcase(String.trim(status)) == "archived"
  end

  defp archived_event?(_), do: false

  defp sync_status_badge_color("completed"), do: "success"
  defp sync_status_badge_color("failed"), do: "danger"
  defp sync_status_badge_color("in_progress"), do: "secondary"
  defp sync_status_badge_color("paused"), do: "warning"
  defp sync_status_badge_color("cancelled"), do: "natural"
  defp sync_status_badge_color(_), do: "natural"
  defp sync_status_label("completed"), do: "Completed"
  defp sync_status_label("failed"), do: "Failed"
  defp sync_status_label("in_progress"), do: "In Progress"
  defp sync_status_label("paused"), do: "Paused"
  defp sync_status_label("cancelled"), do: "Cancelled"
  defp sync_status_label(_), do: "Unknown"

  defp format_datetime(nil), do: "-"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_datetime(_), do: "-"

  defp format_duration(nil), do: "-"

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

  defp format_duration(_), do: "-"
end
