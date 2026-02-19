defmodule FastCheckWeb.ScannerPortalLive do
  @moduledoc """
  Mobile-first scanner-only portal locked to a single event.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.{Attendees, Events}
  alias Phoenix.PubSub

  require Logger

  @default_camera_permission %{status: :unknown, remembered: false, message: nil}
  @valid_tabs ~w(overview camera attendees)

  @impl true
  def mount(%{"event_id" => event_id_param} = params, session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         :ok <- ensure_scanner_session_event(session, event_id),
         {:ok, event} <- fetch_event(event_id) do
      stats = Attendees.get_event_stats(event_id)
      occupancy = Attendees.get_occupancy_breakdown(event_id)
      current_occupancy = Map.get(occupancy, :currently_inside, 0)
      occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)
      active_tab = normalize_tab(Map.get(params, "tab"))
      operator_name = session_value(session, :scanner_operator_name) || "Scanner"

      socket =
        socket
        |> assign(
          event: event,
          event_id: event_id,
          operator_name: operator_name,
          active_tab: active_tab,
          menu_open: false,
          operator_form_open: false,
          check_in_type: "entry",
          ticket_code: "",
          last_scan_status: nil,
          last_scan_result: nil,
          last_scan_reason: nil,
          scan_history: [],
          stats: stats,
          current_occupancy: current_occupancy,
          occupancy_percentage: occupancy_percentage,
          search_query: "",
          search_results: [],
          search_loading: false,
          search_error: nil,
          camera_permission: default_camera_permission(),
          syncing: false,
          sync_progress: nil,
          sync_status: nil,
          sync_status_kind: :info,
          sync_task_pid: nil
        )
        |> assign_event_state()

      socket =
        if connected?(socket) do
          PubSub.subscribe(FastCheck.PubSub, event_topic(event_id))
          PubSub.subscribe(FastCheck.PubSub, occupancy_topic(event_id))
          schedule_event_state_refresh(socket)
        else
          socket
        end

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Scanner session is invalid. Please sign in again.")
         |> push_navigate(to: ~p"/scanner/login")}
    end
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply,
     socket
     |> assign(:active_tab, normalize_tab(tab))
     |> assign(:menu_open, false)
     |> assign(:operator_form_open, false)}
  end

  def handle_event("set_tab", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_menu", _params, socket) do
    menu_open = !socket.assigns.menu_open

    {:noreply,
     socket
     |> assign(:menu_open, menu_open)
     |> assign(
       :operator_form_open,
       if(menu_open, do: socket.assigns.operator_form_open, else: false)
     )}
  end

  @impl true
  def handle_event("toggle_operator_form", _params, socket) do
    {:noreply, assign(socket, :operator_form_open, !socket.assigns.operator_form_open)}
  end

  @impl true
  def handle_event("close_sync_status", _params, socket) do
    {:noreply, assign(socket, :sync_status, nil)}
  end

  @impl true
  def handle_event("set_check_in_type", %{"type" => type}, socket) do
    case normalize_check_in_type(type) do
      nil ->
        {:noreply, socket}

      normalized_type ->
        trimmed_query = String.trim(socket.assigns.search_query || "")

        socket =
          socket
          |> assign(:check_in_type, normalized_type)
          |> assign(
            :search_results,
            apply_mode_filter(socket.assigns.search_results, normalized_type)
          )

        if trimmed_query == "" do
          {:noreply, socket}
        else
          send(self(), {:perform_attendee_search, trimmed_query})
          {:noreply, assign(socket, :search_loading, true)}
        end
    end
  end

  def handle_event("set_check_in_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("scan", %{"ticket_code" => code_param}, socket) do
    code = code_param |> to_string() |> String.trim()

    if code == "" do
      {:noreply,
       socket
       |> assign(:ticket_code, "")
       |> assign(:last_scan_status, :invalid)
       |> assign(:last_scan_result, "No ticket detected. Please try again.")
       |> assign(:last_scan_reason, nil)}
    else
      process_scan(code, socket)
    end
  end

  def handle_event("scan", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("scan_camera_decoded", %{"ticket_code" => code_param}, socket) do
    code = code_param |> to_string() |> String.trim()

    if code == "" do
      {:noreply, socket}
    else
      process_scan(code, socket)
    end
  end

  def handle_event("scan_camera_decoded", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_code", %{"ticket_code" => code}, socket) do
    {:noreply, assign(socket, :ticket_code, to_string(code))}
  end

  def handle_event("update_code", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search_attendees", %{"query" => query_param}, socket) do
    query = query_param |> to_string()
    trimmed_query = String.trim(query)

    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:search_error, nil)

    if trimmed_query == "" do
      {:noreply,
       socket
       |> assign(:search_results, [])
       |> assign(:search_loading, false)}
    else
      send(self(), {:perform_attendee_search, trimmed_query})
      {:noreply, assign(socket, :search_loading, true)}
    end
  end

  def handle_event("search_attendees", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("manual_scan", %{"ticket_code" => ticket_code}, socket) do
    process_scan(ticket_code, socket)
  end

  def handle_event("manual_scan", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_incremental_sync", _params, socket) do
    if socket.assigns.syncing do
      {:noreply, socket}
    else
      parent = self()
      event_id = socket.assigns.event_id

      case Task.start_link(fn ->
             result =
               Events.sync_event(
                 event_id,
                 fn page, total, count ->
                   send(parent, {:scanner_sync_progress, page, total, count})
                 end,
                 incremental: true
               )

             send(parent, {:scanner_sync_complete, result})
           end) do
        {:ok, pid} ->
          {:noreply,
           socket
           |> assign(:syncing, true)
           |> assign(:sync_task_pid, pid)
           |> assign(:sync_progress, {0, 0, 0})
           |> assign(:sync_status, "Starting incremental sync...")
           |> assign(:sync_status_kind, :info)
           |> assign(:menu_open, false)
           |> assign(:operator_form_open, false)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:sync_status, "Unable to start incremental sync: #{inspect(reason)}")
           |> assign(:sync_status_kind, :danger)
           |> assign(:menu_open, false)
           |> assign(:operator_form_open, false)}
      end
    end
  end

  @impl true
  def handle_event("camera_permission_sync", params, socket) when is_map(params) do
    status = normalize_camera_permission_status(Map.get(params, "status"))
    remembered = truthy?(Map.get(params, "remembered"))

    message =
      params
      |> Map.get("message")
      |> normalize_camera_permission_message()
      |> case do
        nil -> camera_permission_default_message(status)
        value -> value
      end

    {:noreply,
     assign(socket, :camera_permission, %{
       status: status,
       remembered: remembered,
       message: message
     })}
  end

  @impl true
  def handle_info({:perform_attendee_search, query}, socket) do
    current_query = socket.assigns.search_query |> to_string() |> String.trim()

    if current_query == query do
      results =
        socket.assigns.event_id
        |> Attendees.search_event_attendees(query, 20)
        |> apply_mode_filter(socket.assigns.check_in_type)

      {:noreply,
       socket
       |> assign(:search_results, results)
       |> assign(:search_loading, false)}
    else
      {:noreply, socket}
    end
  rescue
    exception ->
      Logger.error("Scanner portal attendee search failed: #{Exception.message(exception)}")

      {:noreply,
       socket
       |> assign(:search_results, [])
       |> assign(:search_loading, false)
       |> assign(:search_error, "Unable to search attendees right now.")}
  end

  def handle_info({:event_stats_updated, event_id, stats}, socket) do
    if socket.assigns.event_id == event_id do
      {:noreply, socket |> assign(:stats, stats) |> assign_event_state()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:occupancy_update, %{event_id: event_id} = payload}, socket)
      when event_id == socket.assigns.event_id do
    {:noreply,
     assign_occupancy(socket, payload.inside_count,
       capacity: payload.capacity,
       percentage: payload.percentage
     )}
  end

  def handle_info({:occupancy_changed, count, _type}, socket) do
    {:noreply, assign_occupancy(socket, count)}
  end

  def handle_info({:occupancy_breakdown_updated, event_id, breakdown}, socket) do
    if socket.assigns.event_id == event_id do
      count =
        breakdown
        |> Map.get(:currently_inside)
        |> case do
          nil -> Map.get(breakdown, "currently_inside")
          value -> value
        end
        |> Kernel.||(0)

      {:noreply, assign_occupancy(socket, count)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:scanner_sync_progress, page, total, count}, socket) do
    {:noreply,
     socket
     |> assign(:sync_progress, {page, total, count})
     |> assign(:sync_status, progress_status(page, total, count))
     |> assign(:sync_status_kind, :info)}
  end

  def handle_info({:scanner_sync_complete, {:ok, message}}, socket) do
    {:noreply,
     socket
     |> refresh_stats()
     |> assign(:syncing, false)
     |> assign(:sync_task_pid, nil)
     |> assign(:sync_progress, nil)
     |> assign(:sync_status, message || "Incremental sync completed")
     |> assign(:sync_status_kind, :success)}
  end

  def handle_info({:scanner_sync_complete, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:syncing, false)
     |> assign(:sync_task_pid, nil)
     |> assign(:sync_progress, nil)
     |> assign(:sync_status, "Incremental sync failed: #{format_error(reason)}")
     |> assign(:sync_status_kind, :danger)}
  end

  def handle_info(:refresh_event_state, socket) do
    {:noreply, socket |> assign_event_state() |> schedule_event_state_refresh()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:scan_form, to_form(%{"ticket_code" => assigns.ticket_code}))
      |> assign(:search_form, to_form(%{"query" => assigns.search_query}))
      |> assign(:operator_form, to_form(%{"operator_name" => assigns.operator_name}))

    ~H"""
    <Layouts.app
      flash={@flash}
      show_nav={false}
      main_class="mx-auto w-full max-w-screen-md px-4 pb-28 pt-4"
    >
      <div id="scanner-portal" class="space-y-4">
        <.card variant="shadow" color="natural" rounded="large" padding="medium">
          <.card_content>
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p
                  style="font-size: var(--fc-text-xs)"
                  class="uppercase tracking-[0.35em] text-fc-text-muted"
                >
                  Scanner portal
                </p>
                <h1 class="mt-2 truncate text-xl font-semibold text-fc-text-primary">
                  {@event.name}
                </h1>
                <p class="mt-1 text-xs text-fc-text-secondary">
                  Code {@event.scanner_login_code || "------"} - {@operator_name}
                </p>
              </div>

              <div
                x-data="{pressed:false}"
                x-on:click="pressed = true; setTimeout(() => pressed = false, 140)"
                x-bind:class="pressed ? 'scale-95' : ''"
                class="transition-transform"
              >
                <.button
                  id="scanner-menu-toggle"
                  type="button"
                  phx-click="toggle_menu"
                  variant="bordered"
                  color="natural"
                  size="small"
                >
                  <.icon name="hero-bars-3" class="size-4" />
                </.button>
              </div>
            </div>

            <div class="mt-4 flex flex-wrap items-center gap-2">
              <.badge color="secondary" variant="bordered" rounded="full">
                {entrance_label(@event.entrance_name)}
              </.badge>

              <.badge color={scanner_lifecycle_badge_color(@event_lifecycle_state)} variant="bordered">
                {scanner_lifecycle_label(@event_lifecycle_state)}
              </.badge>
            </div>

            <.button_group
              id="scanner-portal-check-in-type-group"
              color="natural"
              rounded="large"
              class="mt-4 w-full"
            >
              <.button
                id="scanner-portal-entry-mode-button"
                type="button"
                phx-click="set_check_in_type"
                phx-value-type="entry"
                data-check-in-type="entry"
                aria-pressed={@check_in_type == "entry"}
                color={if(@check_in_type == "entry", do: "success", else: "natural")}
                variant={if(@check_in_type == "entry", do: "shadow", else: "bordered")}
                class="w-full"
                disabled={@scans_disabled?}
              >
                Entry
              </.button>

              <.button
                id="scanner-portal-exit-mode-button"
                type="button"
                phx-click="set_check_in_type"
                phx-value-type="exit"
                data-check-in-type="exit"
                aria-pressed={@check_in_type == "exit"}
                color={if(@check_in_type == "exit", do: "warning", else: "natural")}
                variant={if(@check_in_type == "exit", do: "shadow", else: "bordered")}
                class="w-full"
                disabled={@scans_disabled?}
              >
                Exit
              </.button>
            </.button_group>
          </.card_content>
        </.card>

        <.card
          :if={@menu_open}
          id="scanner-menu-panel"
          variant="outline"
          color="natural"
          rounded="large"
          padding="small"
        >
          <.card_content>
            <div
              class="space-y-2"
              x-data="{pendingAction: null, mark(action){ this.pendingAction = action }}"
            >
              <div
                x-on:click="mark('sync')"
                x-bind:class="pendingAction === 'sync' ? 'opacity-70' : ''"
                class="transition-opacity"
              >
                <.button
                  id="scanner-menu-sync"
                  type="button"
                  phx-click="start_incremental_sync"
                  variant="bordered"
                  color="secondary"
                  full_width
                  disabled={@syncing}
                >
                  <span :if={!@syncing} x-show="pendingAction !== 'sync'">Run incremental sync</span>
                  <span :if={!@syncing} x-show="pendingAction === 'sync'">Starting...</span>
                  <span :if={@syncing}>Syncing...</span>
                </.button>
              </div>

              <div
                x-on:click="mark('operator')"
                x-bind:class="pendingAction === 'operator' ? 'opacity-70' : ''"
                class="transition-opacity"
              >
                <.button
                  id="scanner-menu-change-operator"
                  type="button"
                  phx-click="toggle_operator_form"
                  variant="bordered"
                  color="natural"
                  full_width
                >
                  {if(@operator_form_open, do: "Cancel operator change", else: "Change operator")}
                </.button>
              </div>

              <.form
                :if={@operator_form_open}
                id="scanner-menu-operator-form"
                for={@operator_form}
                action={~p"/scanner/#{@event_id}/operator"}
                method="post"
                class="space-y-2 rounded-xl border border-fc-border-default p-3"
              >
                <input
                  type="hidden"
                  name="redirect_to"
                  value={~p"/scanner/#{@event_id}?tab=#{@active_tab}"}
                />
                <.input
                  id="scanner-menu-operator-name"
                  field={@operator_form[:operator_name]}
                  type="text"
                  label="Operator name"
                  autocomplete="name"
                  required
                />
                <div x-data="{saving:false}" x-on:click="saving = true" class="transition-opacity">
                  <.button
                    id="scanner-menu-operator-save"
                    type="submit"
                    color="primary"
                    variant="shadow"
                    full_width
                  >
                    <span x-show="!saving">Save operator</span>
                    <span x-show="saving">Saving...</span>
                  </.button>
                </div>
              </.form>

              <div
                x-on:click="mark('logout')"
                x-bind:class="pendingAction === 'logout' ? 'opacity-70' : ''"
                class="transition-opacity"
              >
                <.link
                  id="scanner-menu-logout"
                  href={~p"/scanner/logout"}
                  method="delete"
                  class="inline-flex w-full items-center justify-center rounded-xl border border-fc-border-default px-4 py-2 text-sm font-medium text-fc-text-primary transition hover:bg-fc-surface-raised"
                >
                  Log out
                </.link>
              </div>
            </div>
          </.card_content>
        </.card>

        <.alert
          :if={@scans_disabled?}
          kind={:danger}
          variant="bordered"
          rounded="large"
          title="Scanning disabled"
        >
          {@scans_disabled_message || "Event archived, scanning disabled"}
        </.alert>

        <div
          :if={@sync_status}
          id="scanner-sync-status"
          x-data="{open: true}"
          x-show="open"
          x-transition:enter="transition ease-out duration-200"
          x-transition:enter-start="opacity-0 translate-y-1"
          x-transition:enter-end="opacity-100 translate-y-0"
          x-transition:leave="transition ease-in duration-150"
          x-transition:leave-start="opacity-100"
          x-transition:leave-end="opacity-0"
        >
          <.alert kind={@sync_status_kind} variant="bordered" rounded="large">
            <div class="flex items-start justify-between gap-3">
              <p class="text-sm">{@sync_status}</p>
              <div x-on:click="open = false">
                <.button
                  type="button"
                  size="extra_small"
                  variant="transparent"
                  color="natural"
                  phx-click="close_sync_status"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>
          </.alert>
        </div>

        <.card
          :if={@last_scan_status}
          id="scanner-portal-scan-result"
          variant="base"
          color={scan_result_color(@last_scan_status, @check_in_type)}
          rounded="large"
          padding="medium"
          data-test="scan-status"
        >
          <.card_content>
            <p class="text-xs uppercase tracking-[0.3em] opacity-80">
              {scan_result_title(@last_scan_status, @check_in_type)}
            </p>
            <p class="mt-2 text-base font-semibold">{@last_scan_result}</p>
            <p :if={@last_scan_reason} class="mt-1 text-xs opacity-85">{@last_scan_reason}</p>
          </.card_content>
        </.card>

        <%= case @active_tab do %>
          <% "overview" -> %>
            <section id="scanner-tab-overview" class="space-y-3" data-test="scanner-tab-overview">
              <div class="grid grid-cols-2 gap-3">
                <.card variant="outline" color="natural" rounded="large" padding="medium">
                  <.card_content>
                    <p class="text-xs uppercase tracking-[0.3em] text-fc-text-muted">
                      Total attendees
                    </p>
                    <p class="mt-2 text-2xl font-semibold text-fc-text-primary">{@stats.total}</p>
                  </.card_content>
                </.card>

                <.card variant="outline" color="success" rounded="large" padding="medium">
                  <.card_content>
                    <p class="text-xs uppercase tracking-[0.3em] opacity-80">Checked in</p>
                    <p class="mt-2 text-2xl font-semibold">{@stats.checked_in}</p>
                  </.card_content>
                </.card>

                <.card variant="outline" color="warning" rounded="large" padding="medium">
                  <.card_content>
                    <p class="text-xs uppercase tracking-[0.3em] opacity-80">Remaining</p>
                    <p class="mt-2 text-2xl font-semibold">{@stats.pending}</p>
                  </.card_content>
                </.card>

                <.card variant="outline" color="secondary" rounded="large" padding="medium">
                  <.card_content>
                    <p class="text-xs uppercase tracking-[0.3em] opacity-80">Currently inside</p>
                    <p class="mt-2 text-2xl font-semibold">{@current_occupancy}</p>
                  </.card_content>
                </.card>
              </div>

              <.card variant="outline" color="natural" rounded="large" padding="medium">
                <.card_content>
                  <div class="flex items-center justify-between">
                    <p class="text-sm text-fc-text-secondary">Crowd load</p>
                    <p class="text-sm font-semibold text-fc-text-primary">
                      {format_percentage(@occupancy_percentage)}%
                    </p>
                  </div>
                  <.progress
                    value={trunc(min(@occupancy_percentage, 100))}
                    color={occupancy_status_color(@occupancy_percentage)}
                    size="small"
                    class="mt-3"
                  />
                </.card_content>
              </.card>
            </section>
          <% "camera" -> %>
            <section id="scanner-tab-camera" class="space-y-3" data-test="scanner-tab-camera">
              <div
                id="scanner-portal-camera-permission-hook"
                phx-hook="CameraPermission"
                data-storage-key={"fastcheck:camera-permission:event-#{@event_id}:portal"}
              >
                <.alert
                  kind={camera_permission_alert_kind(@camera_permission.status)}
                  variant="bordered"
                >
                  <p class="font-semibold">
                    {camera_permission_status_label(@camera_permission.status)}
                  </p>
                  <p class="mt-1 text-xs">
                    {@camera_permission.message ||
                      camera_permission_default_message(@camera_permission.status)}
                  </p>
                </.alert>

                <.button
                  :if={@camera_permission.status != :granted}
                  id="scanner-portal-camera-enable-button"
                  type="button"
                  data-camera-request
                  color="success"
                  class="mt-2"
                  disabled={@camera_permission.status == :unsupported}
                >
                  Enable camera
                </.button>
              </div>

              <.card
                id="scanner-portal-qr-camera"
                phx-hook="QrCameraScanner"
                data-scans-disabled={if(@scans_disabled?, do: "true", else: "false")}
                variant="outline"
                color="natural"
                rounded="large"
                padding="medium"
              >
                <.card_content>
                  <div class="overflow-hidden rounded-2xl border border-fc-border bg-black">
                    <video
                      id="scanner-portal-camera-preview"
                      data-qr-video
                      class="h-[62vh] w-full object-cover"
                      autoplay
                      muted
                      playsinline
                    >
                    </video>
                    <canvas data-qr-canvas class="hidden"></canvas>
                  </div>

                  <p data-qr-status class="mt-3 text-sm text-fc-text-secondary">
                    Camera is idle. Start scanning when ready.
                  </p>
                  <p data-qr-last class="mt-1 text-xs text-fc-text-muted"></p>

                  <.form
                    id="scanner-portal-scan-form"
                    for={@scan_form}
                    phx-submit="scan"
                    phx-change="update_code"
                    class="hidden"
                  >
                    <.input
                      id="scanner-ticket-code"
                      field={@scan_form[:ticket_code]}
                      type="text"
                      autocomplete="off"
                    />
                  </.form>

                  <div class="mt-4 grid grid-cols-2 gap-2">
                    <.button
                      id="scanner-portal-start-camera-button"
                      type="button"
                      data-qr-start
                      color="success"
                      full_width
                      disabled={@scans_disabled?}
                    >
                      Start
                    </.button>

                    <.button
                      id="scanner-portal-stop-camera-button"
                      type="button"
                      data-qr-stop
                      variant="bordered"
                      color="natural"
                      full_width
                      disabled
                    >
                      Stop
                    </.button>
                  </div>
                </.card_content>
              </.card>
            </section>
          <% "attendees" -> %>
            <section id="scanner-tab-attendees" class="space-y-3" data-test="scanner-tab-attendees">
              <.card variant="outline" color="natural" rounded="large" padding="medium">
                <.card_content>
                  <.form
                    id="scanner-portal-search-form"
                    for={@search_form}
                    phx-change="search_attendees"
                  >
                    <.input
                      id="scanner-portal-search-input"
                      field={@search_form[:query]}
                      type="search"
                      placeholder="Search by name, email, or ticket code"
                      autocomplete="off"
                      phx-debounce="300"
                    />
                  </.form>

                  <p :if={@search_error} class="mt-3 text-sm text-danger-light dark:text-danger-dark">
                    {@search_error}
                  </p>

                  <p :if={@search_loading} class="mt-3 text-sm text-fc-text-secondary">
                    Searching attendees...
                  </p>

                  <div :if={@search_results != []} class="mt-4 space-y-2">
                    <.card
                      :for={attendee <- @search_results}
                      variant="outline"
                      color="natural"
                      rounded="medium"
                      padding="small"
                    >
                      <.card_content>
                        <div class="flex items-center justify-between gap-3">
                          <div class="min-w-0">
                            <p class="truncate text-sm font-semibold text-fc-text-primary">
                              {attendee.first_name} {attendee.last_name}
                            </p>
                            <p class="truncate text-xs text-fc-text-secondary">
                              {attendee.ticket_code}
                            </p>
                          </div>

                          <.button
                            type="button"
                            phx-click="manual_scan"
                            phx-value-ticket_code={attendee.ticket_code}
                            color={manual_action_color(@check_in_type)}
                            variant="bordered"
                            size="small"
                            disabled={
                              !attendee_actionable?(attendee, @check_in_type) || @scans_disabled?
                            }
                            data-test={"manual-check-in-#{attendee.ticket_code}"}
                          >
                            {manual_action_label(@check_in_type)}
                          </.button>
                        </div>
                      </.card_content>
                    </.card>
                  </div>

                  <p
                    :if={
                      @search_results == [] and @search_query != "" and not @search_loading and
                        is_nil(@search_error)
                    }
                    class="mt-4 text-sm text-fc-text-secondary"
                  >
                    No attendees found for "{@search_query}".
                  </p>
                </.card_content>
              </.card>
            </section>
        <% end %>
      </div>

      <nav
        id="scanner-bottom-nav"
        class="fixed inset-x-0 bottom-0 border-t border-fc-border-default bg-fc-surface-raised/95 px-4 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2 backdrop-blur"
      >
        <div class="mx-auto grid max-w-screen-md grid-cols-3 items-end gap-3">
          <.button
            id="scanner-tab-button-overview"
            type="button"
            phx-click="set_tab"
            phx-value-tab="overview"
            color={if(@active_tab == "overview", do: "primary", else: "natural")}
            variant={if(@active_tab == "overview", do: "shadow", else: "bordered")}
            size="small"
            full_width
          >
            Overview
          </.button>

          <div class="flex justify-center">
            <div
              x-data="{pressed:false}"
              x-on:click="pressed = true; setTimeout(() => pressed = false, 160)"
              x-bind:class="pressed ? 'scale-95' : ''"
              class="transition-transform"
            >
              <.button
                id="scanner-tab-button-camera"
                type="button"
                phx-click="set_tab"
                phx-value-tab="camera"
                color={if(@active_tab == "camera", do: "primary", else: "secondary")}
                variant={if(@active_tab == "camera", do: "shadow", else: "base")}
                rounded="full"
                class="h-14 w-14 -translate-y-2 shadow-lg"
              >
                <.icon name="hero-camera" class="size-6" />
                <span class="sr-only">Camera</span>
              </.button>
            </div>
          </div>

          <.button
            id="scanner-tab-button-attendees"
            type="button"
            phx-click="set_tab"
            phx-value-tab="attendees"
            color={if(@active_tab == "attendees", do: "primary", else: "natural")}
            variant={if(@active_tab == "attendees", do: "shadow", else: "bordered")}
            size="small"
            full_width
          >
            Attendees
          </.button>
        </div>
      </nav>
    </Layouts.app>
    """
  end

  defp process_scan(code, socket) do
    if socket.assigns.scans_disabled? do
      message = socket.assigns.scans_disabled_message || "Scanning is disabled for this event."

      {:noreply,
       socket
       |> assign(:last_scan_status, :archived)
       |> assign(:last_scan_result, message)
       |> assign(:last_scan_reason, nil)
       |> assign(:ticket_code, "")}
    else
      do_process_scan(code, socket)
    end
  end

  defp do_process_scan(code, socket) do
    event_id = socket.assigns.event_id
    entrance_name = socket.assigns.event.entrance_name || "Main Entrance"
    operator_name = socket.assigns.operator_name
    mode = socket.assigns.check_in_type
    sanitized_code = String.trim(code)

    domain_result =
      case mode do
        "exit" ->
          Attendees.check_out(event_id, sanitized_code, entrance_name, operator_name)

        _ ->
          Attendees.check_in_advanced(
            event_id,
            sanitized_code,
            "entry",
            entrance_name,
            operator_name
          )
      end

    case domain_result do
      {:ok, attendee, _message} ->
        entry =
          build_scan_history_entry(
            sanitized_code,
            attendee,
            :success,
            success_message(attendee, mode),
            mode
          )

        socket =
          socket
          |> refresh_stats()
          |> assign(
            last_scan_status: :success,
            last_scan_result: success_message(attendee, mode),
            last_scan_reason: nil,
            ticket_code: "",
            scan_history: add_to_scan_history(socket.assigns.scan_history, entry)
          )
          |> push_event("scan_result", %{status: "success"})

        {:noreply, socket}

      {:error, error_code, message} ->
        normalized_status = normalize_error_code(error_code)

        entry =
          build_scan_history_entry(
            sanitized_code,
            nil,
            normalized_status,
            message,
            mode
          )

        socket =
          socket
          |> assign(
            last_scan_status: normalized_status,
            last_scan_result: message,
            last_scan_reason: scan_reason(normalized_status),
            ticket_code: "",
            scan_history: add_to_scan_history(socket.assigns.scan_history, entry)
          )
          |> maybe_disable_scanning(error_code, message)
          |> push_event("scan_result", %{status: "error"})

        {:noreply, socket}
    end
  end

  defp maybe_disable_scanning(socket, error_code, message)
       when error_code in ["ARCHIVED_EVENT", "SCANS_DISABLED"] do
    socket
    |> assign(:scans_disabled?, true)
    |> assign(:scans_disabled_message, message)
  end

  defp maybe_disable_scanning(socket, _error_code, _message), do: socket

  defp refresh_stats(socket) do
    event_id = socket.assigns.event_id
    stats = Attendees.get_event_stats(event_id)
    occupancy = Attendees.get_occupancy_breakdown(event_id)
    inside_count = Map.get(occupancy, :currently_inside, 0)
    percentage = calculate_occupancy_percentage(inside_count, stats.total)

    socket
    |> assign(:stats, stats)
    |> assign(:current_occupancy, inside_count)
    |> assign(:occupancy_percentage, percentage)
    |> assign_event_state()
  end

  defp assign_event_state(socket) do
    event = socket.assigns.event_id |> Events.get_event_with_stats()
    lifecycle_state = Events.event_lifecycle_state(event)

    {scans_disabled?, scans_disabled_message} =
      case Events.can_check_in?(event) do
        {:ok, _state} -> {false, nil}
        {:error, {_reason, message}} -> {true, message || "Scanning is disabled for this event."}
      end

    socket
    |> assign(:event, event)
    |> assign(:event_lifecycle_state, lifecycle_state)
    |> assign(:scans_disabled?, scans_disabled?)
    |> assign(:scans_disabled_message, scans_disabled_message)
  rescue
    _ ->
      socket
  end

  defp schedule_event_state_refresh(socket) do
    Process.send_after(self(), :refresh_event_state, 30_000)
    socket
  end

  defp build_scan_history_entry(ticket_code, attendee, status, message, check_in_type) do
    name = if attendee, do: "#{attendee.first_name} #{attendee.last_name}", else: nil

    %{
      ticket_code: ticket_code,
      name: name,
      status: status,
      message: message,
      check_in_type: check_in_type,
      scanned_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp add_to_scan_history(history, entry), do: [entry | history] |> Enum.take(10)

  defp scan_reason(:duplicate_today), do: "Already scanned"
  defp scan_reason(:already_inside), do: "Attendee already inside"
  defp scan_reason(:limit_exceeded), do: "No check-ins remaining"
  defp scan_reason(:not_checked_in), do: "Attendee is not currently inside"
  defp scan_reason(_), do: nil

  defp scan_result_color(:success, "entry"), do: "success"
  defp scan_result_color(:success, "exit"), do: "warning"
  defp scan_result_color(:duplicate_today, _), do: "warning"
  defp scan_result_color(:already_inside, _), do: "warning"
  defp scan_result_color(:archived, _), do: "natural"
  defp scan_result_color(:invalid, _), do: "danger"
  defp scan_result_color(:limit_exceeded, _), do: "danger"
  defp scan_result_color(:not_checked_in, _), do: "danger"
  defp scan_result_color(:not_yet_valid, _), do: "danger"
  defp scan_result_color(:expired, _), do: "danger"
  defp scan_result_color(:error, _), do: "danger"
  defp scan_result_color(_, _), do: "natural"

  defp scan_result_title(:success, "entry"), do: "Entry confirmed"
  defp scan_result_title(:success, "exit"), do: "Exit confirmed"
  defp scan_result_title(:duplicate_today, _), do: "Duplicate scan"
  defp scan_result_title(:already_inside, _), do: "Already inside"
  defp scan_result_title(:limit_exceeded, _), do: "Check-in limit reached"
  defp scan_result_title(:not_checked_in, _), do: "Cannot check out"
  defp scan_result_title(:not_yet_valid, _), do: "Ticket not yet valid"
  defp scan_result_title(:expired, _), do: "Ticket expired"
  defp scan_result_title(:invalid, _), do: "Invalid ticket"
  defp scan_result_title(:archived, _), do: "Scanning unavailable"
  defp scan_result_title(:error, _), do: "Scan error"
  defp scan_result_title(_, _), do: "Scan status"

  defp normalize_error_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> case do
      "duplicate_today" -> :duplicate_today
      "duplicate" -> :duplicate_today
      "already_inside" -> :already_inside
      "limit_exceeded" -> :limit_exceeded
      "not_checked_in" -> :not_checked_in
      "not_yet_valid" -> :not_yet_valid
      "expired" -> :expired
      "invalid" -> :invalid
      "invalid_ticket" -> :invalid
      "not_found" -> :invalid
      "archived_event" -> :archived
      "scans_disabled" -> :archived
      _ -> :error
    end
  end

  defp success_message(attendee, "exit"),
    do: "Exit confirmed for #{attendee_first_name(attendee)}."

  defp success_message(attendee, _), do: "Welcome, #{attendee_first_name(attendee)}."

  defp attendee_first_name(%{} = attendee) do
    attendee
    |> Map.get(:first_name)
    |> case do
      value when is_binary(value) and value != "" -> String.trim(value)
      _ -> attendee_display_name(attendee)
    end
  end

  defp attendee_display_name(attendee) do
    [
      Map.get(attendee, :first_name),
      Map.get(attendee, :last_name),
      Map.get(attendee, :email),
      Map.get(attendee, :ticket_code),
      "Guest"
    ]
    |> Enum.find(fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
    |> case do
      nil -> "Guest"
      value -> String.trim(value)
    end
  end

  defp apply_mode_filter(results, "exit") do
    results
    |> Enum.filter(&exit_actionable?/1)
    |> Enum.sort_by(fn attendee -> attendee_sort_key(attendee, false) end)
  end

  defp apply_mode_filter(results, _mode) do
    Enum.sort_by(results, fn attendee ->
      attendee_sort_key(attendee, entry_actionable?(attendee))
    end)
  end

  defp attendee_sort_key(attendee, actionable?) do
    {
      if(actionable?, do: 0, else: 1),
      attendee |> Map.get(:last_name, "") |> String.downcase(),
      attendee |> Map.get(:first_name, "") |> String.downcase(),
      Map.get(attendee, :id) || 0
    }
  end

  defp attendee_actionable?(attendee, "exit"), do: exit_actionable?(attendee)
  defp attendee_actionable?(attendee, _), do: entry_actionable?(attendee)

  defp entry_actionable?(attendee) do
    remaining =
      attendee
      |> Map.get(:checkins_remaining)
      |> case do
        value when is_integer(value) -> value
        _ -> Map.get(attendee, :allowed_checkins) || 0
      end

    remaining > 0 and Map.get(attendee, :is_currently_inside) != true
  end

  defp exit_actionable?(attendee), do: Map.get(attendee, :is_currently_inside) == true

  defp manual_action_label("exit"), do: "Check out"
  defp manual_action_label(_), do: "Check in"

  defp manual_action_color("exit"), do: "warning"
  defp manual_action_color(_), do: "success"

  defp default_camera_permission, do: @default_camera_permission

  defp normalize_tab(value) when value in @valid_tabs, do: value
  defp normalize_tab(_), do: "camera"

  defp normalize_check_in_type(value) when value in ["entry", "exit"], do: value

  defp normalize_check_in_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "entry" -> "entry"
      "exit" -> "exit"
      _ -> nil
    end
  end

  defp normalize_check_in_type(_), do: nil

  defp parse_event_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {event_id, ""} when event_id > 0 -> {:ok, event_id}
      _ -> {:error, :invalid_event_id}
    end
  end

  defp parse_event_id(_), do: {:error, :invalid_event_id}

  defp fetch_event(event_id) do
    {:ok, Events.get_event_with_stats(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp ensure_scanner_session_event(session, event_id) do
    with true <- truthy?(session_value(session, :scanner_authenticated)),
         {:ok, session_event_id} <- parse_event_id(session_value(session, :scanner_event_id)),
         true <- session_event_id == event_id do
      :ok
    else
      _ -> {:error, :invalid_scanner_session}
    end
  end

  defp session_value(session, key) do
    key_string = Atom.to_string(key)
    Map.get(session, key_string) || Map.get(session, key)
  end

  defp event_topic(event_id), do: "event:#{event_id}:stats"
  defp occupancy_topic(event_id), do: "event:#{event_id}:occupancy"

  defp assign_occupancy(socket, count, opts \\ []) do
    sanitized_count = sanitize_non_neg_integer(count)

    capacity =
      opts
      |> Keyword.get(:capacity)
      |> case do
        nil -> derive_capacity_from_socket(socket)
        value -> normalize_capacity(value)
      end

    percentage =
      opts
      |> Keyword.get(:percentage)
      |> case do
        nil -> calculate_occupancy_percentage(sanitized_count, capacity)
        value -> normalize_percentage(value)
      end

    assign(socket,
      current_occupancy: sanitized_count,
      occupancy_percentage: percentage
    )
  end

  defp derive_capacity_from_socket(socket) do
    event_total = socket.assigns.event && Map.get(socket.assigns.event, :total_tickets)
    stats_total = socket.assigns.stats && Map.get(socket.assigns.stats, :total)
    normalize_capacity(event_total || stats_total || 0)
  end

  defp calculate_occupancy_percentage(count, capacity) do
    capacity_value = normalize_capacity(capacity)

    cond do
      capacity_value <= 0 ->
        0.0

      true ->
        count_clamped = min(count, capacity_value)
        Float.round(count_clamped / capacity_value * 100, 1)
    end
  end

  defp normalize_capacity(value) when is_integer(value) and value > 0, do: value
  defp normalize_capacity(value) when is_float(value) and value > 0, do: trunc(value)
  defp normalize_capacity(_), do: 0

  defp normalize_percentage(value) when is_number(value) do
    value
    |> max(0)
    |> min(100)
    |> Float.round(1)
  end

  defp normalize_percentage(_), do: 0.0

  defp sanitize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp sanitize_non_neg_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp sanitize_non_neg_integer(_), do: 0

  defp format_percentage(value) when is_number(value),
    do: :erlang.float_to_binary(value, decimals: 1)

  defp format_percentage(_), do: "0.0"

  defp occupancy_status_color(percentage) when percentage >= 95, do: "danger"
  defp occupancy_status_color(percentage) when percentage > 75, do: "warning"
  defp occupancy_status_color(_), do: "success"

  defp scanner_lifecycle_badge_color(:archived), do: "danger"
  defp scanner_lifecycle_badge_color(:grace), do: "warning"
  defp scanner_lifecycle_badge_color(:upcoming), do: "natural"
  defp scanner_lifecycle_badge_color(:unknown), do: "natural"
  defp scanner_lifecycle_badge_color(_), do: "success"

  defp scanner_lifecycle_label(:active), do: "Active"
  defp scanner_lifecycle_label(:grace), do: "Grace period"
  defp scanner_lifecycle_label(:upcoming), do: "Upcoming"
  defp scanner_lifecycle_label(:archived), do: "Archived"
  defp scanner_lifecycle_label(_), do: "Unknown"

  defp progress_status(page, total, count) do
    if total in [nil, 0] do
      "Syncing attendees... Imported #{count} records"
    else
      "Syncing attendees (page #{page}/#{total}) - Imported #{count} records"
    end
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, fn message -> "#{field} #{message}" end)
      end)

    Enum.join(errors, ", ")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp entrance_label(nil), do: "Main Entrance"
  defp entrance_label(""), do: "Main Entrance"
  defp entrance_label(value), do: value

  defp camera_permission_alert_kind(:granted), do: :success
  defp camera_permission_alert_kind(:denied), do: :danger
  defp camera_permission_alert_kind(:error), do: :danger
  defp camera_permission_alert_kind(:unsupported), do: :warning
  defp camera_permission_alert_kind(_), do: :info

  defp camera_permission_status_label(:granted), do: "Camera enabled"
  defp camera_permission_status_label(:denied), do: "Camera blocked"
  defp camera_permission_status_label(:error), do: "Camera error"
  defp camera_permission_status_label(:unsupported), do: "Camera unsupported"
  defp camera_permission_status_label(_), do: "Camera ready"

  defp camera_permission_default_message(:granted),
    do: "Camera access granted. You can start scanning."

  defp camera_permission_default_message(:denied),
    do: "Camera access was denied. Enable it in your browser settings."

  defp camera_permission_default_message(:error),
    do: "Something went wrong while accessing the camera."

  defp camera_permission_default_message(:unsupported),
    do: "This browser does not support camera scanning."

  defp camera_permission_default_message(_),
    do: "Enable camera access to scan QR codes faster."

  defp normalize_camera_permission_status("granted"), do: :granted
  defp normalize_camera_permission_status("denied"), do: :denied
  defp normalize_camera_permission_status("error"), do: :error
  defp normalize_camera_permission_status("unsupported"), do: :unsupported
  defp normalize_camera_permission_status(value) when is_atom(value), do: value
  defp normalize_camera_permission_status(_), do: :unknown

  defp normalize_camera_permission_message(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_camera_permission_message(_), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_), do: false
end
