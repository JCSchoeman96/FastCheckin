defmodule FastCheckWeb.ScannerPortalLive do
  @moduledoc """
  Mobile-first scanner-only portal locked to a single event.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.{Attendees, Events}
  alias Phoenix.PubSub
  import FastCheckWeb.Components.ScannerComponents

  require Logger

  @default_camera_permission %{status: :unknown, remembered: false, message: nil}
  @default_camera_runtime %{
    state: :idle,
    recoverable: true,
    desired_active: false,
    message: "Camera idle."
  }
  @default_stats_reconcile_ms 30_000
  @default_force_refresh_every_n_scans 20
  @scan_feedback_clear_ms 5_000
  @search_row_success_ms 1_200
  @error_status_map %{
    "duplicate_today" => :already_used,
    "duplicate" => :already_used,
    "already_inside" => :already_inside,
    "limit_exceeded" => :limit_exceeded,
    "not_checked_in" => :not_checked_in,
    "payment_invalid" => :payment_invalid,
    "invalid" => :invalid_ticket,
    "invalid_ticket" => :invalid_ticket,
    "not_found" => :invalid_ticket,
    "event_not_found" => :invalid_ticket,
    "ticket_in_use_elsewhere" => :busy_retry,
    "archived_event" => :scanner_closed,
    "scans_disabled" => :scanner_closed
  }

  @impl true
  def mount(%{"event_id" => event_id_param}, session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         :ok <- ensure_scanner_session_event(session, event_id),
         {:ok, event} <- fetch_event(event_id) do
      stats = Attendees.get_event_stats(event_id)
      occupancy = Attendees.get_occupancy_breakdown(event_id)
      current_occupancy = Map.get(occupancy, :currently_inside, 0)
      occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)
      operator_name = session_value(session, :scanner_operator_name) || "Scanner"
      stats_reconcile_ms = scanner_stats_reconcile_ms()
      force_refresh_every_n_scans = scanner_force_refresh_every_n_scans()

      socket =
        socket
        |> assign(
          event: event,
          event_id: event_id,
          operator_name: operator_name,
          menu_open: false,
          drawer_section: nil,
          check_in_type: "entry",
          ticket_code: "",
          last_scan_status: nil,
          last_scan_result: nil,
          last_scan_reason: nil,
          scan_feedback: nil,
          scan_feedback_ref: 0,
          scan_history: [],
          stats: stats,
          current_occupancy: current_occupancy,
          occupancy_percentage: occupancy_percentage,
          successful_scan_count: 0,
          stats_reconcile_ms: stats_reconcile_ms,
          force_refresh_every_n_scans: force_refresh_every_n_scans,
          search_query: "",
          search_results: [],
          search_row_actions: %{},
          search_row_action_ref: 0,
          search_loading: false,
          search_error: nil,
          camera_permission: default_camera_permission(),
          camera_runtime: default_camera_runtime(),
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

          socket
          |> schedule_event_state_refresh()
          |> schedule_stats_reconcile()
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
  def handle_event("toggle_menu", _params, socket) do
    menu_open = !socket.assigns.menu_open

    {:noreply,
     socket
     |> assign(:menu_open, menu_open)
     |> assign(:drawer_section, if(menu_open, do: socket.assigns.drawer_section, else: nil))}
  end

  @impl true
  def handle_event("set_drawer_section", %{"section" => section}, socket) do
    next_section = normalize_drawer_section(section)

    drawer_section =
      if socket.assigns.drawer_section == next_section do
        nil
      else
        next_section
      end

    {:noreply,
     socket
     |> assign(:menu_open, true)
     |> assign(:drawer_section, drawer_section)}
  end

  def handle_event("set_drawer_section", _params, socket), do: {:noreply, socket}

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
          |> assign(:search_row_actions, %{})

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
       |> assign(:last_scan_status, :invalid_ticket)
       |> assign(:last_scan_result, "No ticket detected. Please try again.")
       |> assign(:last_scan_reason, nil)
       |> assign_scan_feedback(:invalid_ticket, "No ticket detected. Please try again.", nil)
       |> push_scan_result(:invalid_ticket)}
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
      |> assign(:search_row_actions, %{})

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
    ticket_code = ticket_code |> to_string() |> String.trim()

    if ticket_code == "" do
      {:noreply, socket}
    else
      mode = socket.assigns.check_in_type

      {socket, action_ref} = begin_search_row_action(socket, ticket_code, mode)
      {socket, status, result} = apply_scan(ticket_code, socket)

      socket =
        case result do
          {:ok, attendee} when status == :accepted ->
            socket
            |> update_search_result_attendee(ticket_code, attendee, mode)
            |> mark_search_row_action_succeeded(ticket_code, mode, action_ref)

          _ ->
            clear_search_row_action(socket, ticket_code)
        end

      {:noreply, socket}
    end
  end

  def handle_event("manual_scan", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_incremental_sync", _params, socket) do
    if socket.assigns.syncing do
      {:noreply, socket}
    else
      {:ok, pid} = start_incremental_sync_task(socket.assigns.event_id, self())
      {:noreply, assign_sync_started(socket, pid)}
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
  def handle_event("camera_runtime_sync", params, socket) when is_map(params) do
    state = normalize_camera_runtime_state(Map.get(params, "state"))
    recoverable = truthy?(Map.get(params, "recoverable"))
    desired_active = truthy?(Map.get(params, "desired_active"))

    message =
      params
      |> Map.get("message")
      |> normalize_camera_runtime_message()
      |> case do
        nil -> camera_runtime_default_message(state)
        value -> value
      end

    {:noreply,
     assign(socket, :camera_runtime, %{
       state: state,
       recoverable: recoverable,
       desired_active: desired_active,
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
       |> assign(:search_loading, false)
       |> prune_search_row_actions()}
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

  def handle_info({:clear_scan_feedback, ref}, socket) do
    case socket.assigns.scan_feedback do
      %{ref: ^ref, persistent?: false} ->
        {:noreply, assign(socket, :scan_feedback, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:settle_search_action, ticket_code, ref}, socket) do
    current_action = Map.get(socket.assigns.search_row_actions, ticket_code)

    socket =
      case current_action do
        %{ref: ^ref, state: :just_succeeded} = action ->
          assign(socket, :search_row_actions, %{
            socket.assigns.search_row_actions
            | ticket_code => %{action | state: :settled_non_actionable}
          })

        _ ->
          socket
      end

    {:noreply, socket}
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
    maybe_warm_event_cache(socket.assigns.event)

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

  def handle_info(:reconcile_scanner_metrics, socket) do
    {:noreply, socket |> refresh_stats() |> schedule_stats_reconcile()}
  end

  def handle_info(:reconcile_scanner_metrics_now, socket) do
    {:noreply, refresh_stats(socket)}
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
      main_class="mx-auto w-full max-w-screen-md px-4 pb-6 pt-4"
    >
      <div id="scanner-portal" class="scanner-field-shell">
        <.scanner_header
          id="scanner-portal-header"
          event_name={@event.name}
          operator_name={@operator_name}
          entrance_label={entrance_label(@event.entrance_name)}
          lifecycle_label={scanner_lifecycle_label(@event_lifecycle_state)}
          lifecycle_color={scanner_lifecycle_badge_color(@event_lifecycle_state)}
          label="Field scanner"
          menu
        />

        <.scanner_mode_toggle
          id="scanner-portal-check-in-type-group"
          check_in_type={@check_in_type}
          entry_id="scanner-portal-entry-mode-button"
          exit_id="scanner-portal-exit-mode-button"
          disabled={@scans_disabled?}
        />

        <section id="scanner-primary-search" class="scanner-primary-search">
          <.form id="scanner-portal-search-form" for={@search_form} phx-change="search_attendees">
            <.input
              id="scanner-portal-search-input"
              field={@search_form[:query]}
              type="search"
              placeholder="Find attendee or ticket"
              autocomplete="off"
              phx-debounce="300"
            />
          </.form>

          <p :if={@search_error} class="text-sm text-danger-light dark:text-danger-dark">
            {@search_error}
          </p>

          <p :if={@search_loading} class="scanner-inline-status">Searching</p>

          <div
            :if={@search_results != [] and String.trim(@search_query || "") != ""}
            class="scanner-search-results"
          >
            <div :for={attendee <- Enum.take(@search_results, 3)} class="scanner-search-result">
              <% row_action = search_row_action(@search_row_actions, attendee, @check_in_type) %>
              <div class="min-w-0">
                <p class="truncate text-sm font-semibold text-fc-text-primary">
                  {attendee.first_name} {attendee.last_name}
                </p>
                <p class="truncate text-xs text-fc-text-secondary">{attendee.ticket_code}</p>
              </div>

              <.button
                type="button"
                phx-click="manual_scan"
                phx-value-ticket_code={attendee.ticket_code}
                color={manual_action_color(@check_in_type, row_action)}
                variant={manual_action_variant(row_action)}
                size="small"
                class={manual_action_class(row_action)}
                phx-disable-with={manual_action_pending_label(@check_in_type)}
                disabled={
                  manual_action_disabled?(attendee, @check_in_type, row_action, @scans_disabled?)
                }
                data-test={"manual-check-in-#{attendee.ticket_code}"}
              >
                <.icon
                  :if={manual_action_icon(row_action)}
                  name={manual_action_icon(row_action)}
                  class="size-4"
                />
                {manual_action_label(@check_in_type, row_action)}
              </.button>
            </div>
          </div>

          <p
            :if={
              @search_results == [] and @search_query != "" and not @search_loading and
                is_nil(@search_error)
            }
            class="scanner-empty-state"
          >
            No attendees found.
          </p>
        </section>

        <aside :if={@menu_open} id="scanner-menu-panel" class="scanner-drawer">
          <div class="scanner-drawer-nav">
            <.button
              id="scanner-menu-change-operator"
              type="button"
              phx-click="set_drawer_section"
              phx-value-section="operator"
              variant={if(@drawer_section == :operator, do: "shadow", else: "bordered")}
              color="natural"
              full_width
            >
              Operator
            </.button>

            <.button
              id="scanner-menu-history"
              type="button"
              phx-click="set_drawer_section"
              phx-value-section="history"
              variant={if(@drawer_section == :history, do: "shadow", else: "bordered")}
              color="natural"
              full_width
            >
              Recent scans
            </.button>
          </div>

          <.form
            :if={@drawer_section == :operator}
            id="scanner-menu-operator-form"
            for={@operator_form}
            action={~p"/scanner/#{@event_id}/operator"}
            method="post"
            class="scanner-drawer-section"
          >
            <div class="scanner-drawer-heading">
              <h2>Operator</h2>
              <p>Change the name recorded with scans.</p>
            </div>
            <input type="hidden" name="redirect_to" value={~p"/scanner/#{@event_id}"} />
            <.input
              id="scanner-menu-operator-name"
              field={@operator_form[:operator_name]}
              type="text"
              label="Operator name"
              autocomplete="name"
              required
            />
            <.button
              id="scanner-menu-operator-save"
              type="submit"
              color="primary"
              variant="shadow"
              full_width
            >
              Save operator
            </.button>
          </.form>

          <div
            :if={@drawer_section == :history}
            id="scanner-drawer-history"
            class="scanner-drawer-section"
          >
            <.compact_recent_scans id="scanner-portal-recent-scans" scans={@scan_history} />
          </div>

          <.link
            id="scanner-menu-logout"
            href={~p"/scanner/logout"}
            method="delete"
            class="scanner-logout-link"
          >
            Log out
          </.link>
        </aside>

        <section
          id="scanner-primary-scan-block"
          class="scanner-camera-stack"
          data-test="scanner-field-camera"
        >
          <div
            id="scanner-portal-qr-camera"
            phx-hook="QrCameraScanner"
            data-scans-disabled={if(@scans_disabled?, do: "true", else: "false")}
            data-resume-key={"fastcheck:camera-runtime:event-#{@event_id}:portal"}
            class="scanner-camera-panel"
          >
            <.camera_action_row
              start_id="scanner-portal-start-camera-button"
              reconnect_id="scanner-portal-reconnect-camera-button"
              stop_id="scanner-portal-stop-camera-button"
              runtime={@camera_runtime}
              scans_disabled={@scans_disabled?}
              start_label="Start scanning"
              variant={:field}
            />

            <p data-qr-status class="scanner-camera-status-text">Camera idle</p>
            <p data-qr-last class="scanner-camera-last-text"></p>

            <div class="scanner-result-slot scanner-result-slot--above">
              <.scan_result_banner
                :if={@scan_feedback}
                id="scanner-portal-scan-result"
                status={@scan_feedback.status}
                check_in_type={@check_in_type}
                message={@scan_feedback.message}
                reason={@scan_feedback.reason}
                size={:field}
                presentation={:field_filled}
                data-test="scan-status"
              />

              <.scan_result_banner
                :if={!@scan_feedback && @scans_disabled?}
                id="scanner-portal-scan-result"
                status={:scanner_closed}
                check_in_type={@check_in_type}
                message={@scans_disabled_message || "Scanning is closed for this event."}
                size={:field}
                presentation={:field_filled}
                data-test="scan-status"
              />
            </div>

            <div
              id="scanner-portal-camera-preview-shell"
              phx-update="ignore"
              class="scanner-camera-preview"
            >
              <video
                id="scanner-portal-camera-preview"
                data-qr-video
                class="scanner-camera-video"
                autoplay
                muted
                playsinline
              >
              </video>
              <canvas data-qr-canvas class="hidden"></canvas>
            </div>
          </div>
        </section>

        <section id="scanner-secondary-tools" class="scanner-secondary-tools">
          <.form
            id="scanner-portal-scan-form"
            for={@scan_form}
            phx-submit="scan"
            phx-change="update_code"
            class="scanner-manual-form"
          >
            <.input
              id="scanner-ticket-code"
              field={@scan_form[:ticket_code]}
              type="text"
              label="Manual code"
              placeholder="Ticket code"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="characters"
              spellcheck="false"
              inputmode="text"
              disabled={@scans_disabled?}
            />
            <.button
              id="scanner-portal-manual-scan-button"
              type="submit"
              color="success"
              variant="bordered"
              full_width
              disabled={@scans_disabled?}
            >
              Process scan
            </.button>
          </.form>

          <section id="scanner-secondary-sync" class="scanner-secondary-panel">
            <div class="scanner-drawer-heading">
              <h2>Sync attendees</h2>
              <p>{if(@syncing, do: "Sync running", else: "Update attendee data")}</p>
            </div>

            <.button
              id="scanner-menu-sync-action"
              type="button"
              phx-click="start_incremental_sync"
              variant="bordered"
              color="secondary"
              full_width
              disabled={@syncing}
            >
              {if(@syncing, do: "Syncing", else: "Run sync")}
            </.button>

            <div :if={@sync_status} id="scanner-sync-status" class="scanner-inline-status">
              <p>{@sync_status}</p>
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
          </section>

          <section
            id="scanner-portal-camera-permission-hook"
            phx-hook="CameraPermission"
            data-storage-key={"fastcheck:camera-permission:event-#{@event_id}:portal"}
            class="scanner-secondary-panel"
          >
            <.camera_status_strip
              id="scanner-portal-camera-status"
              runtime_id="scanner-portal-camera-runtime-status"
              permission={@camera_permission}
              runtime={@camera_runtime}
            />

            <div class="scanner-permission-actions">
              <.button
                :if={@camera_permission.status != :granted}
                id="scanner-portal-camera-enable-button"
                type="button"
                data-camera-request
                color="success"
                disabled={@camera_permission.status == :unsupported}
              >
                Enable camera
              </.button>

              <.button
                id="scanner-portal-camera-recheck-button"
                type="button"
                data-camera-recheck
                variant="bordered"
                color="natural"
                disabled={@camera_permission.status == :unsupported}
              >
                Check permission
              </.button>
            </div>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp process_scan(code, socket) do
    {socket, _status, _result} = apply_scan(code, socket)
    {:noreply, socket}
  end

  defp apply_scan(code, socket) do
    if socket.assigns.scans_disabled? do
      message = socket.assigns.scans_disabled_message || "Scanning is disabled for this event."

      socket =
        socket
        |> assign(:last_scan_status, :scanner_closed)
        |> assign(:last_scan_result, message)
        |> assign(:last_scan_reason, nil)
        |> assign(:ticket_code, "")
        |> assign_scan_feedback(:scanner_closed, message, nil, persistent?: true)
        |> push_scan_result(:scanner_closed)

      {socket, :scanner_closed, {:error, :scanner_closed}}
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
            :accepted,
            success_message(attendee, mode),
            mode
          )

        socket =
          socket
          |> assign(
            last_scan_status: :accepted,
            last_scan_result: success_message(attendee, mode),
            last_scan_reason: nil,
            ticket_code: "",
            scan_history: add_to_scan_history(socket.assigns.scan_history, entry)
          )
          |> assign_scan_feedback(:accepted, success_message(attendee, mode), nil)
          |> apply_optimistic_scan_metrics(mode)
          |> maybe_force_scan_reconcile()
          |> push_scan_result(:accepted)

        {socket, :accepted, {:ok, attendee}}

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
          |> assign_scan_feedback(
            normalized_status,
            message,
            scan_reason(normalized_status),
            persistent?: normalized_status == :scanner_closed
          )
          |> push_scan_result(normalized_status)

        {socket, normalized_status, {:error, error_code}}
    end
  end

  defp maybe_disable_scanning(socket, error_code, message)
       when error_code in ["ARCHIVED_EVENT", "SCANS_DISABLED"] do
    socket
    |> assign(:scans_disabled?, true)
    |> assign(:scans_disabled_message, message)
  end

  defp maybe_disable_scanning(socket, _error_code, _message), do: socket

  defp assign_scan_feedback(socket, status, message, reason, opts \\ []) do
    ref = socket.assigns.scan_feedback_ref + 1
    persistent? = Keyword.get(opts, :persistent?, false)

    feedback = %{
      ref: ref,
      status: status,
      message: message,
      reason: reason,
      persistent?: persistent?
    }

    if connected?(socket) and not persistent? do
      Process.send_after(self(), {:clear_scan_feedback, ref}, @scan_feedback_clear_ms)
    end

    assign(socket, scan_feedback: feedback, scan_feedback_ref: ref)
  end

  defp begin_search_row_action(socket, ticket_code, mode) do
    ref = socket.assigns.search_row_action_ref + 1

    actions =
      Map.put(socket.assigns.search_row_actions, ticket_code, %{
        ref: ref,
        mode: mode,
        state: :pending
      })

    socket =
      assign(socket,
        search_row_actions: actions,
        search_row_action_ref: ref
      )

    {socket, ref}
  end

  defp mark_search_row_action_succeeded(socket, ticket_code, mode, ref) do
    action = %{ref: ref, mode: mode, state: :just_succeeded}

    if connected?(socket) do
      Process.send_after(
        self(),
        {:settle_search_action, ticket_code, ref},
        @search_row_success_ms
      )
    end

    assign(
      socket,
      :search_row_actions,
      Map.put(socket.assigns.search_row_actions, ticket_code, action)
    )
  end

  defp clear_search_row_action(socket, ticket_code) do
    assign(
      socket,
      :search_row_actions,
      Map.delete(socket.assigns.search_row_actions, ticket_code)
    )
  end

  defp prune_search_row_actions(socket) do
    visible_codes =
      socket.assigns.search_results
      |> Enum.map(&Map.get(&1, :ticket_code))
      |> MapSet.new()

    mode = socket.assigns.check_in_type

    actions =
      Map.filter(socket.assigns.search_row_actions, fn {ticket_code, action} ->
        MapSet.member?(visible_codes, ticket_code) and Map.get(action, :mode) == mode
      end)

    assign(socket, :search_row_actions, actions)
  end

  defp update_search_result_attendee(socket, ticket_code, attendee, mode) do
    results =
      Enum.map(socket.assigns.search_results, fn result ->
        if Map.get(result, :ticket_code) == ticket_code do
          apply_attendee_scan_state(result, attendee, mode)
        else
          result
        end
      end)

    assign(socket, :search_results, results)
  end

  defp apply_attendee_scan_state(result, attendee, "exit") do
    %{result | is_currently_inside: false, checked_out_at: Map.get(attendee, :checked_out_at)}
  end

  defp apply_attendee_scan_state(result, attendee, _mode) do
    checkins_remaining =
      case Map.get(attendee, :checkins_remaining) do
        value when is_integer(value) -> value
        _ -> max(current_checkins_remaining(result) - 1, 0)
      end

    %{result | is_currently_inside: true, checkins_remaining: checkins_remaining}
  end

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
    event = socket.assigns.event_id |> Events.get_event!()
    lifecycle_state = Events.event_lifecycle_state(event)

    {scans_disabled?, scans_disabled_message} =
      case Events.can_check_in?(event) do
        {:ok, _state} -> {false, nil}
        {:error, {_reason, message}} -> {true, message}
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

  defp schedule_stats_reconcile(socket) do
    Process.send_after(self(), :reconcile_scanner_metrics, socket.assigns.stats_reconcile_ms)
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

  defp scan_reason(:already_used), do: "Already scanned"
  defp scan_reason(:already_inside), do: "Attendee already inside"
  defp scan_reason(:limit_exceeded), do: "No check-ins remaining"
  defp scan_reason(:not_checked_in), do: "Attendee is not currently inside"
  defp scan_reason(:payment_invalid), do: "Order status is not completed"
  defp scan_reason(:busy_retry), do: "Ticket is being processed"
  defp scan_reason(_), do: nil

  defp normalize_error_code(code) do
    code
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> then(&Map.get(@error_status_map, &1, :system_error))
  end

  defp push_scan_result(socket, status) do
    push_event(socket, "scan_result", %{
      status: Atom.to_string(status),
      sound: scan_sound(status)
    })
  end

  defp scan_sound(:accepted), do: "success"

  defp scan_sound(status) when status in [:already_used, :already_inside, :busy_retry],
    do: "warning"

  defp scan_sound(_), do: "error"

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
    current_checkins_remaining(attendee) > 0 and Map.get(attendee, :is_currently_inside) != true
  end

  defp exit_actionable?(attendee), do: Map.get(attendee, :is_currently_inside) == true

  defp current_checkins_remaining(attendee) do
    attendee
    |> Map.get(:checkins_remaining)
    |> case do
      value when is_integer(value) -> value
      _ -> Map.get(attendee, :allowed_checkins) || 0
    end
  end

  defp search_row_action(actions, attendee, mode) do
    ticket_code = Map.get(attendee, :ticket_code)

    case Map.get(actions, ticket_code) do
      %{mode: ^mode} = action -> action
      _ -> %{state: :idle, mode: mode}
    end
  end

  defp manual_action_label("exit", %{state: :pending}), do: "Checking out..."
  defp manual_action_label("exit", %{state: :just_succeeded}), do: "Checked out"
  defp manual_action_label("exit", %{state: :settled_non_actionable}), do: "Not inside"
  defp manual_action_label("exit", _action), do: "Check out"
  defp manual_action_label(_mode, %{state: :pending}), do: "Checking in..."
  defp manual_action_label(_mode, %{state: :just_succeeded}), do: "Checked in"
  defp manual_action_label(_mode, %{state: :settled_non_actionable}), do: "Already inside"
  defp manual_action_label(_mode, _action), do: "Check in"

  defp manual_action_pending_label("exit"), do: "Checking out..."
  defp manual_action_pending_label(_), do: "Checking in..."

  defp manual_action_color(_mode, %{state: state}) when state in [:pending, :just_succeeded],
    do: "success"

  defp manual_action_color("exit", %{state: :settled_non_actionable}), do: "natural"
  defp manual_action_color(_mode, %{state: :settled_non_actionable}), do: "warning"
  defp manual_action_color("exit", _action), do: "warning"
  defp manual_action_color(_mode, _action), do: "success"

  defp manual_action_variant(%{state: state}) when state in [:pending, :just_succeeded],
    do: "shadow"

  defp manual_action_variant(_action), do: "bordered"

  defp manual_action_class(%{state: state}) when state in [:pending, :just_succeeded],
    do: "scanner-search-action scanner-search-action--active"

  defp manual_action_class(%{state: :settled_non_actionable}),
    do: "scanner-search-action scanner-search-action--settled"

  defp manual_action_class(_action), do: "scanner-search-action"

  defp manual_action_icon(%{state: :just_succeeded}), do: "hero-check-circle"
  defp manual_action_icon(_action), do: nil

  defp manual_action_disabled?(_attendee, _mode, %{state: state}, _scans_disabled?)
       when state in [:pending, :just_succeeded, :settled_non_actionable],
       do: true

  defp manual_action_disabled?(attendee, mode, _action, scans_disabled?) do
    scans_disabled? or not attendee_actionable?(attendee, mode)
  end

  defp default_camera_permission, do: @default_camera_permission

  defp normalize_drawer_section("operator"), do: :operator
  defp normalize_drawer_section("history"), do: :history

  defp normalize_drawer_section(value) when value in [:operator, :history],
    do: value

  defp normalize_drawer_section(_), do: nil

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
    {:ok, Events.get_event!(event_id)}
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

    if capacity_value <= 0 do
      0.0
    else
      count_clamped = min(count, capacity_value)
      Float.round(count_clamped / capacity_value * 100, 1)
    end
  end

  defp start_incremental_sync_task(event_id, parent) do
    Task.start_link(fn ->
      result =
        Events.sync_event(
          event_id,
          fn page, total, count ->
            send(parent, {:scanner_sync_progress, page, total, count})
          end,
          incremental: true
        )

      send(parent, {:scanner_sync_complete, result})
    end)
  end

  defp assign_sync_started(socket, pid) do
    socket
    |> assign(:syncing, true)
    |> assign(:sync_task_pid, pid)
    |> assign(:sync_progress, {0, 0, 0})
    |> assign(:sync_status, "Starting incremental sync...")
    |> assign(:sync_status_kind, :info)
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

  defp default_camera_runtime, do: @default_camera_runtime

  defp camera_permission_default_message(:granted),
    do: "Camera ready."

  defp camera_permission_default_message(:denied),
    do: "Camera blocked. Enable it in your browser settings."

  defp camera_permission_default_message(:error),
    do: "Camera error."

  defp camera_permission_default_message(:unsupported),
    do: "Camera unsupported. Use manual entry."

  defp camera_permission_default_message(_),
    do: "Enable camera to start scanning."

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

  defp normalize_camera_runtime_state("starting"), do: :starting
  defp normalize_camera_runtime_state("running"), do: :running
  defp normalize_camera_runtime_state("paused"), do: :paused
  defp normalize_camera_runtime_state("recovering"), do: :recovering
  defp normalize_camera_runtime_state("error"), do: :error
  defp normalize_camera_runtime_state(value) when is_atom(value), do: value
  defp normalize_camera_runtime_state(_), do: :idle

  defp normalize_camera_runtime_message(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_camera_runtime_message(_), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy?(_), do: false

  defp camera_runtime_default_message(:starting),
    do: "Camera starting."

  defp camera_runtime_default_message(:running),
    do: "Camera running."

  defp camera_runtime_default_message(:paused),
    do: "Camera paused."

  defp camera_runtime_default_message(:recovering),
    do: "Camera reconnecting."

  defp camera_runtime_default_message(:error),
    do: "Reconnect camera."

  defp camera_runtime_default_message(_),
    do: "Camera idle."

  defp apply_optimistic_scan_metrics(socket, mode) do
    current_stats = socket.assigns.stats || %{total: 0, checked_in: 0, pending: 0}
    total = Map.get(current_stats, :total, 0)
    checked_in = Map.get(current_stats, :checked_in, 0)
    pending = Map.get(current_stats, :pending, 0)
    current_occupancy = socket.assigns.current_occupancy || 0
    successful_scan_count = (socket.assigns.successful_scan_count || 0) + 1

    {updated_checked_in, updated_pending, updated_occupancy} =
      case mode do
        "exit" ->
          {checked_in, pending, max(current_occupancy - 1, 0)}

        _ ->
          {min(checked_in + 1, total), max(pending - 1, 0), current_occupancy + 1}
      end

    updated_stats =
      current_stats
      |> Map.put(:checked_in, updated_checked_in)
      |> Map.put(:pending, updated_pending)

    assign(socket,
      stats: updated_stats,
      current_occupancy: updated_occupancy,
      occupancy_percentage: calculate_occupancy_percentage(updated_occupancy, total),
      successful_scan_count: successful_scan_count
    )
  end

  defp maybe_force_scan_reconcile(socket) do
    force_every =
      socket.assigns.force_refresh_every_n_scans || @default_force_refresh_every_n_scans

    count = socket.assigns.successful_scan_count || 0

    if force_every > 0 and rem(count, force_every) == 0 do
      send(self(), :reconcile_scanner_metrics_now)
    end

    socket
  end

  defp scanner_stats_reconcile_ms do
    :fastcheck
    |> Application.get_env(:scanner_performance, [])
    |> Keyword.get(:stats_reconcile_ms, @default_stats_reconcile_ms)
  end

  defp scanner_force_refresh_every_n_scans do
    :fastcheck
    |> Application.get_env(:scanner_performance, [])
    |> Keyword.get(:force_refresh_every_n_scans, @default_force_refresh_every_n_scans)
  end

  defp maybe_warm_event_cache(event) when is_map(event) do
    cond do
      not scanner_warmup_enabled?() ->
        :ok

      sandbox_pool?() ->
        Events.warm_event_cache(event)
        :ok

      true ->
        caller = self()

        {:ok, _pid} =
          Task.start(fn ->
            maybe_allow_sandbox_connection(caller)
            Events.warm_event_cache(event)
          end)

        :ok
    end
  rescue
    exception ->
      Logger.warning("Scanner cache warmup raised: #{Exception.message(exception)}")
      :ok
  end

  defp maybe_warm_event_cache(_event), do: :ok

  defp scanner_warmup_enabled? do
    :fastcheck
    |> Application.get_env(:scanner_performance, [])
    |> Keyword.get(:warmup_on_login, true)
  end

  defp maybe_allow_sandbox_connection(caller) when is_pid(caller) do
    if sandbox_pool?() do
      try do
        Ecto.Adapters.SQL.Sandbox.allow(FastCheck.Repo, caller, self())
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  defp sandbox_pool? do
    Application.get_env(:fastcheck, FastCheck.Repo, [])
    |> Keyword.get(:pool)
    |> Kernel.==(Ecto.Adapters.SQL.Sandbox)
  end
end
