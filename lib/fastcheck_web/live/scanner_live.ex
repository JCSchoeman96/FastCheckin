defmodule FastCheckWeb.ScannerLive do
  @moduledoc """
  Real-time scanner interface for on-site staff to check in attendees via QR codes.
  """

  use FastCheckWeb, :live_view

  alias FastCheck.{Attendees, Events}
  alias Phoenix.LiveView.JS
  alias Phoenix.PubSub
  require Logger

  @default_camera_permission %{status: :unknown, remembered: false, message: nil}
  @default_stats_reconcile_ms 30_000
  @default_force_refresh_every_n_scans 20

  @impl true
  def mount(%{"event_id" => event_id_param}, _session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, event} <- fetch_event(event_id) do
      stats = Attendees.get_event_stats(event_id)
      occupancy = Attendees.get_occupancy_breakdown(event_id)
      current_occupancy = Map.get(occupancy, :currently_inside, 0)
      occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)
      stats_reconcile_ms = scanner_stats_reconcile_ms()
      force_refresh_every_n_scans = scanner_force_refresh_every_n_scans()

      socket =
        socket
        |> assign(
          event: event,
          event_id: event_id,
          ticket_code: "",
          last_scan_status: nil,
          last_scan_result: nil,
          last_scan_reason: nil,
          last_scan_checkins_used: 0,
          last_scan_checkins_allowed: 0,
          stats: stats,
          check_in_type: "entry",
          current_occupancy: current_occupancy,
          occupancy_percentage: occupancy_percentage,
          successful_scan_count: 0,
          stats_reconcile_ms: stats_reconcile_ms,
          force_refresh_every_n_scans: force_refresh_every_n_scans,
          search_query: "",
          search_results: [],
          search_loading: false,
          search_error: nil,
          camera_permission: default_camera_permission(),
          scan_history: [],
          sound_enabled: true,
          bulk_mode: false,
          bulk_codes: "",
          bulk_processing: false,
          bulk_results: []
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
         |> put_flash(:error, "Event not found")
         |> push_navigate(to: ~p"/dashboard")}
    end
  end

  @impl true
  def handle_event("scan", %{"ticket_code" => code_param}, socket) do
    code = code_param |> to_string() |> String.trim()

    if code == "" do
      {:noreply,
       socket
       |> assign(:ticket_code, "")
       |> assign(:last_scan_status, :invalid)
       |> assign(:last_scan_result, "No ticket detected. Please try again.")}
    else
      process_scan(code, socket)
    end
  end

  def handle_event("scan", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("scan_camera_decoded", %{"ticket_code" => code_param}, socket) do
    code = code_param |> to_string() |> String.trim()

    if code == "" do
      {:noreply, socket}
    else
      process_scan(code, socket)
    end
  end

  def handle_event("scan_camera_decoded", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_check_in_type", %{"type" => type}, socket) do
    case normalize_check_in_type(type) do
      nil -> {:noreply, socket}
      normalized -> {:noreply, assign(socket, :check_in_type, normalized)}
    end
  end

  def handle_event("set_check_in_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_code", %{"ticket_code" => code}, socket) do
    {:noreply, assign(socket, :ticket_code, to_string(code))}
  end

  def handle_event("update_code", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search_attendees", %{"query" => query_param}, socket) do
    query = query_param |> to_string()
    trimmed = String.trim(query)

    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:search_error, nil)

    cond do
      trimmed == "" ->
        {:noreply,
         socket
         |> assign(:search_results, [])
         |> assign(:search_loading, false)}

      true ->
        send(self(), {:perform_attendee_search, trimmed})

        {:noreply, assign(socket, :search_loading, true)}
    end
  end

  def handle_event("search_attendees", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("manual_check_in", %{"ticket_code" => ticket_code}, socket) do
    process_scan(ticket_code, socket)
  end

  def handle_event("manual_check_in", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_scan_history", _params, socket) do
    {:noreply, assign(socket, :scan_history, [])}
  end

  @impl true
  def handle_event("sound_toggle", %{"enabled" => enabled}, socket) do
    {:noreply, assign(socket, :sound_enabled, enabled)}
  end

  def handle_event("sound_toggle", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_bulk_mode", _params, socket) do
    new_mode = !socket.assigns.bulk_mode

    {:noreply,
     socket
     |> assign(:bulk_mode, new_mode)
     |> assign(:bulk_codes, if(new_mode, do: socket.assigns.bulk_codes, else: ""))
     |> assign(:bulk_results, [])}
  end

  @impl true
  def handle_event("update_bulk_codes", %{"codes" => codes}, socket) do
    {:noreply, assign(socket, :bulk_codes, codes)}
  end

  def handle_event("update_bulk_codes", params, socket) when is_map(params) do
    # Handle case where codes might be in different format
    codes = Map.get(params, "codes", socket.assigns.bulk_codes)
    {:noreply, assign(socket, :bulk_codes, codes)}
  end

  def handle_event("update_bulk_codes", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("process_bulk_codes", %{"codes" => codes_param}, socket) do
    codes =
      codes_param
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if Enum.empty?(codes) do
      {:noreply,
       socket
       |> assign(:bulk_results, [%{status: :error, message: "No ticket codes provided."}])}
    else
      # Start async processing
      send(self(), {:process_bulk_codes_async, codes})

      {:noreply,
       socket
       |> assign(:bulk_processing, true)
       |> assign(:bulk_results, [])}
    end
  end

  def handle_event("process_bulk_codes", _params, socket) do
    {:noreply, socket}
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

  def handle_info({:perform_attendee_search, query}, socket) do
    current_query = socket.assigns.search_query |> to_string() |> String.trim()

    if current_query == query do
      results = Attendees.search_event_attendees(socket.assigns.event_id, query, 10)

      {:noreply,
       socket
       |> assign(:search_results, results)
       |> assign(:search_loading, false)}
    else
      {:noreply, socket}
    end
  rescue
    exception ->
      Logger.error("Failed to search attendees: #{Exception.message(exception)}")

      {:noreply,
       socket
       |> assign(:search_results, [])
       |> assign(:search_loading, false)
       |> assign(:search_error, "Unable to search attendees right now.")}
  end

  def handle_info(:refresh_event_state, socket) do
    {:noreply, socket |> assign_event_state() |> schedule_event_state_refresh()}
  end

  def handle_info(:reconcile_scanner_metrics, socket) do
    event_id = socket.assigns.event_id
    stats = Attendees.get_event_stats(event_id)
    occupancy = Attendees.get_occupancy_breakdown(event_id)
    current_occupancy = Map.get(occupancy, :currently_inside, 0)
    occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:current_occupancy, current_occupancy)
     |> assign(:occupancy_percentage, occupancy_percentage)
     |> schedule_stats_reconcile()}
  end

  def handle_info(:reconcile_scanner_metrics_now, socket) do
    event_id = socket.assigns.event_id
    stats = Attendees.get_event_stats(event_id)
    occupancy = Attendees.get_occupancy_breakdown(event_id)
    current_occupancy = Map.get(occupancy, :currently_inside, 0)
    occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:current_occupancy, current_occupancy)
     |> assign(:occupancy_percentage, occupancy_percentage)}
  end

  @impl true
  def handle_info({:process_bulk_codes_async, codes}, socket) do
    check_in_type = socket.assigns.check_in_type || "entry"
    event_id = socket.assigns.event_id
    entrance_name = socket.assigns.event.entrance_name || "Main"
    bulk_operator = if(check_in_type == "exit", do: "Bulk Exit", else: "Bulk Entry")

    # Process each code sequentially
    results =
      Enum.map(codes, fn code ->
        case perform_scan_action(event_id, code, check_in_type, entrance_name, bulk_operator) do
          {:ok, attendee, message} ->
            scan_entry =
              build_scan_history_entry(code, attendee, :success, message, check_in_type)

            %{
              code: code,
              status: :success,
              attendee: attendee,
              message: message,
              scan_entry: scan_entry
            }

          {:error, error_code, message} ->
            # Normalize error code to lowercase atom for consistent status matching
            # Error codes from Attendees.check_in_advanced are uppercase strings like "LIMIT_EXCEEDED"
            # but scan_status_color/icon functions expect lowercase atoms like :limit_exceeded
            # Use normalize_error_code/1 to safely convert to known atoms only
            normalized_status = normalize_error_code(error_code)

            scan_entry =
              build_scan_history_entry(code, nil, normalized_status, message, check_in_type)

            %{
              code: code,
              status: :error,
              error_code: error_code,
              message: message,
              scan_entry: scan_entry
            }
        end
      end)

    # Update scan history with all results
    updated_history =
      Enum.reduce(results, socket.assigns.scan_history, fn result, acc ->
        if result.scan_entry do
          add_to_scan_history(acc, result.scan_entry)
        else
          acc
        end
      end)

    # Refresh stats
    stats = Attendees.get_event_stats(event_id)
    occupancy = Attendees.get_occupancy_breakdown(event_id)
    current_occupancy = Map.get(occupancy, :currently_inside, 0)
    occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)

    success_count = Enum.count(results, &(&1.status == :success))
    error_count = Enum.count(results, &(&1.status == :error))

    {:noreply,
     socket
     |> assign(:bulk_processing, false)
     |> assign(:bulk_results, results)
     |> assign(:scan_history, updated_history)
     |> assign(:stats, stats)
     |> assign(:current_occupancy, current_occupancy)
     |> assign(:occupancy_percentage, occupancy_percentage)
     |> assign(:last_scan_status, if(success_count > 0, do: :success, else: :error))
     |> assign(
       :last_scan_result,
       "Processed #{length(results)} codes: #{success_count} successful, #{error_count} errors"
     )}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:scan_form, to_form(%{"ticket_code" => assigns.ticket_code}))
      |> assign(:search_form, to_form(%{"query" => assigns.search_query}))
      |> assign(:bulk_form, to_form(%{"codes" => assigns.bulk_codes}))

    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="admin-scanner-root"
        phx-hook="ScannerKeyboardShortcuts"
        class="min-h-screen space-y-6 sm:space-y-8 bg-scanner-dark"
      >
        <.card variant="outline" color="natural" rounded="large" padding="large" class="glass-card glass-sheen glass-card-deep">
          <.card_content>
            <p
              style="font-size: var(--fc-text-xs)"
              class="uppercase tracking-[0.35em] text-fc-text-muted"
            >
              Event check-in
            </p>

            <h1 style="font-size: var(--fc-text-3xl)" class="mt-3 font-semibold text-fc-text-primary">
              {@event.name}
            </h1>

            <div class="mt-6 flex flex-wrap items-center gap-3">
              <.badge color="secondary" variant="bordered" rounded="full">
                {entrance_label(@event.entrance_name)}
              </.badge>

              <.badge
                color={scanner_lifecycle_badge_color(@event_lifecycle_state)}
                variant="bordered"
                rounded="full"
              >
                {scanner_lifecycle_label(@event_lifecycle_state)}
              </.badge>
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

        <.card
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
          class="fc-card-container glass-card glass-sheen"
        >
          <.card_content>
            <div class="flex flex-col gap-6">
              <div class="space-y-2">
                <p
                  style="font-size: var(--fc-text-xs)"
                  class="uppercase tracking-[0.35em] text-fc-text-muted"
                >
                  Scanner mode
                </p>

                <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
                  Entry and exit controls
                </h2>

                <p class="text-sm text-fc-text-secondary">
                  Switch direction instantly while keeping the field focused for rapid scans.
                </p>
              </div>

              <.button_group
                id="check-in-type-group"
                color="natural"
                rounded="large"
                class="w-full cq-card:flex-row"
              >
                <.button
                  id="entry-mode-button"
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
                  <span class="inline-flex items-center gap-2">
                    <.icon name="hero-arrow-right-circle" class="size-4" /> Entry
                  </span>
                </.button>

                <.button
                  id="exit-mode-button"
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
                  <span class="inline-flex items-center gap-2">
                    <.icon name="hero-arrow-left-circle" class="size-4" /> Exit
                  </span>
                </.button>
              </.button_group>

              <.card variant="base" color="secondary" rounded="large" padding="large">
                <.card_content>
                  <div class="flex flex-col gap-4 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
                    <div>
                      <p class="text-sm uppercase tracking-[0.3em] opacity-80">Current occupancy</p>
                      <p style="font-size: var(--fc-text-4xl)" class="mt-2 font-semibold">
                        {@current_occupancy}
                      </p>
                      <p class="text-sm opacity-85">Guests currently inside</p>
                    </div>

                    <div class="cq-sm:text-right">
                      <p class="text-sm uppercase tracking-[0.3em] opacity-80">Capacity</p>
                      <p style="font-size: var(--fc-text-3xl)" class="mt-2 font-semibold">
                        {format_percentage(@occupancy_percentage)}%
                      </p>
                      <.badge
                        color={occupancy_status_color(@occupancy_percentage)}
                        variant="bordered"
                        rounded="full"
                        class="mt-3"
                      >
                        Crowd load
                      </.badge>
                    </div>
                  </div>

                  <.progress
                    value={trunc(min(@occupancy_percentage, 100))}
                    color="secondary"
                    size="small"
                    class="mt-5"
                  />
                </.card_content>
              </.card>
            </div>
          </.card_content>
        </.card>

        <section class="grid gap-4 cq-md:grid-cols-3 sm:grid-cols-3">
          <.card
            variant="outline"
            color="natural"
            rounded="large"
            padding="medium"
            class="fc-card-container glass-card"
          >
            <.card_content>
              <p class="text-xs uppercase tracking-[0.3em] text-fc-text-muted">Total tickets</p>
              <p style="font-size: var(--fc-text-2xl)" class="mt-2 font-semibold text-fc-text-primary">
                {@stats.total}
              </p>
            </.card_content>
          </.card>

          <.card
            variant="outline"
            color="success"
            rounded="large"
            padding="medium"
            class="fc-card-container glass-card"
          >
            <.card_content>
              <p class="text-xs uppercase tracking-[0.3em] opacity-80">Checked in</p>
              <p style="font-size: var(--fc-text-2xl)" class="mt-2 font-semibold">
                {@stats.checked_in}
              </p>
            </.card_content>
          </.card>

          <.card
            variant="outline"
            color="warning"
            rounded="large"
            padding="medium"
            class="fc-card-container glass-card"
          >
            <.card_content>
              <p class="text-xs uppercase tracking-[0.3em] opacity-80">Pending</p>
              <p style="font-size: var(--fc-text-2xl)" class="mt-2 font-semibold">
                {@stats.pending}
              </p>
            </.card_content>
          </.card>
        </section>

        <.card
          :if={@last_scan_status}
          id="scan-result"
          data-test="scan-status"
          variant="base"
          color={scan_result_color(@last_scan_status, @check_in_type)}
          rounded="large"
          padding="large"
          phx-remove={JS.add_class("opacity-0", transition: "transition-opacity duration-300")}
        >
          <.card_content>
            <div class="space-y-3">
              <p class="text-xs uppercase tracking-[0.3em] opacity-80">
                {scan_result_title(@last_scan_status, @check_in_type)}
              </p>

              <p style="font-size: var(--fc-text-2xl)" class="font-semibold">
                {@last_scan_result}
              </p>

              <p :if={@last_scan_reason} class="text-sm opacity-85">
                {@last_scan_reason}
              </p>

              <div
                :if={@last_scan_status == :success and @last_scan_checkins_allowed > 1}
                class="space-y-2"
              >
                <p class="text-sm opacity-90">
                  Check-ins used: {@last_scan_checkins_used} of {@last_scan_checkins_allowed}
                </p>
                <.progress
                  value={
                    checkins_used_percentage(@last_scan_checkins_used, @last_scan_checkins_allowed)
                  }
                  color={scan_result_color(@last_scan_status, @check_in_type)}
                  size="small"
                />
              </div>

              <p class="text-sm opacity-85">
                Current occupancy: {@current_occupancy} inside
              </p>
            </div>
          </.card_content>
        </.card>

        <section
          id="camera-permission-hook"
          phx-hook="CameraPermission"
          data-storage-key={"fastcheck:camera-permission:event-#{@event_id}"}
        >
          <div class="space-y-4">
            <.card
              variant="outline"
              color="natural"
              rounded="large"
              padding="large"
              class="fc-card-container glass-card glass-sheen"
            >
              <.card_content>
                <div class="flex flex-col gap-4 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
                  <div>
                    <p
                      style="font-size: var(--fc-text-xs)"
                      class="uppercase tracking-[0.35em] text-fc-text-muted"
                    >
                      Camera status
                    </p>
                    <h2
                      style="font-size: var(--fc-text-2xl)"
                      class="mt-2 font-semibold text-fc-text-primary"
                    >
                      Ready the QR scanner
                    </h2>
                    <p class="mt-2 text-sm text-fc-text-secondary">
                      Your decision is saved for this device.
                    </p>
                  </div>

                  <.badge
                    color={camera_permission_badge_color(@camera_permission.status)}
                    variant="bordered"
                    rounded="full"
                  >
                    {camera_permission_status_label(@camera_permission.status)}
                  </.badge>
                </div>

                <.alert
                  kind={camera_permission_alert_kind(@camera_permission.status)}
                  variant="bordered"
                  rounded="large"
                  class="mt-6"
                >
                  <p class="font-semibold">
                    {camera_permission_status_label(@camera_permission.status)}
                  </p>
                  <p class="mt-1 text-sm">
                    {@camera_permission.message ||
                      camera_permission_default_message(@camera_permission.status)}
                  </p>
                </.alert>

                <div class="mt-6 flex flex-wrap items-center gap-3">
                  <.button
                    :if={@camera_permission.status != :granted}
                    id="camera-enable-button"
                    type="button"
                    data-camera-request
                    color="success"
                    variant="shadow"
                    disabled={@camera_permission.status == :unsupported}
                  >
                    Enable camera
                  </.button>

                  <p class="text-xs text-fc-text-muted">
                    {if @camera_permission.remembered do
                      "Preference synced from this device."
                    else
                      "Your decision will be remembered for future check-ins."
                    end}
                  </p>
                </div>
              </.card_content>
            </.card>

            <.card
              id="qr-camera-scanner"
              phx-hook="QrCameraScanner"
              phx-update="ignore"
              data-scans-disabled={if(@scans_disabled?, do: "true", else: "false")}
              variant="outline"
              color="natural"
              rounded="large"
              padding="large"
              class="fc-card-container glass-card glass-sheen"
            >
              <.card_content>
                <div class="flex flex-col gap-4 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
                  <div>
                    <h3
                      style="font-size: var(--fc-text-xl)"
                      class="font-semibold text-fc-text-primary"
                    >
                      Live QR camera scan
                    </h3>
                    <p class="mt-2 text-sm text-fc-text-secondary">
                      Start the camera to decode QR codes directly in-browser.
                    </p>
                  </div>

                  <.badge color="secondary" variant="bordered" rounded="full">
                    Browser decoder
                  </.badge>
                </div>

                <div class="mt-5 overflow-hidden rounded-2xl border border-fc-border bg-black">
                  <video
                    id="qr-camera-preview"
                    data-qr-video
                    class="h-56 w-full object-cover md:h-72"
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

                <div class="mt-4 grid gap-2 cq-sm:grid-cols-2">
                  <.button
                    id="start-camera-scan"
                    type="button"
                    data-qr-start
                    color="success"
                    variant="shadow"
                    full_width
                    disabled={@scans_disabled?}
                  >
                    Start camera scan
                  </.button>

                  <.button
                    id="stop-camera-scan"
                    type="button"
                    data-qr-stop
                    variant="bordered"
                    color="natural"
                    full_width
                    disabled
                  >
                    Stop camera
                  </.button>
                </div>
              </.card_content>
            </.card>
          </div>
        </section>

        <section id="scanner-keyboard-shortcuts">
          <.card
            variant="outline"
            color="natural"
            rounded="large"
            padding="large"
            class="fc-card-container glass-card glass-sheen"
          >
            <.card_content>
              <div class="flex flex-col gap-4 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
                <div>
                  <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
                    Scan tickets
                  </h2>
                  <p :if={!@bulk_mode} class="mt-2 text-sm text-fc-text-secondary">
                    Use the QR scanner or type a code below.
                  </p>
                  <p :if={@bulk_mode} class="mt-2 text-sm text-fc-text-secondary">
                    Paste one ticket code per line for bulk processing.
                  </p>
                </div>

                <div class="flex items-center gap-2">
                  <.button
                    id="bulk-mode-toggle"
                    type="button"
                    phx-click="toggle_bulk_mode"
                    variant="bordered"
                    color={if(@bulk_mode, do: "secondary", else: "natural")}
                    size="small"
                    aria-label={
                      if(@bulk_mode,
                        do: "Switch to single scan mode",
                        else: "Switch to bulk scan mode"
                      )
                    }
                  >
                    {if(@bulk_mode, do: "Bulk mode", else: "Bulk")}
                  </.button>

                  <.button
                    id="sound-toggle"
                    type="button"
                    phx-hook="SoundToggle"
                    variant="bordered"
                    color={if(@sound_enabled, do: "success", else: "natural")}
                    size="small"
                    aria-label={
                      if(@sound_enabled, do: "Disable sound feedback", else: "Enable sound feedback")
                    }
                  >
                    {if(@sound_enabled, do: "Sound on", else: "Sound off")}
                  </.button>
                </div>
              </div>

              <div :if={!@bulk_mode} class="mt-6">
                <.form
                  id="scanner-form"
                  for={@scan_form}
                  phx-submit="scan"
                  phx-change="update_code"
                  class="cq-sm:max-w-md mx-auto"
                >
                  <.input
                    id="scanner-ticket-code"
                    field={@scan_form[:ticket_code]}
                    type="text"
                    placeholder="Point scanner at QR code"
                    autocomplete="off"
                    autocorrect="off"
                    autocapitalize="characters"
                    spellcheck="false"
                    inputmode="text"
                    autofocus
                    disabled={@scans_disabled?}
                  />

                  <.button
                    id="process-scan-button"
                    type="submit"
                    color="success"
                    variant="shadow"
                    full_width
                    class="mt-4"
                    disabled={@scans_disabled?}
                    aria-disabled={@scans_disabled?}
                  >
                    Process scan
                  </.button>
                </.form>

                <p class="mt-4 text-center text-xs text-fc-text-muted">
                  Keyboard: Enter to scan, Tab to toggle direction.
                </p>
              </div>

              <div :if={@bulk_mode} class="mt-6">
                <.form id="bulk-scan-form" for={@bulk_form} phx-submit="process_bulk_codes">
                  <.input
                    field={@bulk_form[:codes]}
                    type="textarea"
                    rows="10"
                    phx-blur="update_bulk_codes"
                    phx-debounce="300"
                    placeholder="Paste ticket codes here, one per line"
                    class="font-mono"
                  />

                  <.button
                    id="process-bulk-button"
                    type="submit"
                    color="success"
                    variant="shadow"
                    full_width
                    class="mt-4"
                    disabled={@bulk_processing || String.trim(@bulk_codes) == ""}
                  >
                    {if(@bulk_processing, do: "Processing...", else: "Process all codes")}
                  </.button>
                </.form>

                <.card
                  :if={@bulk_results != []}
                  variant="outline"
                  color="natural"
                  rounded="large"
                  padding="medium"
                  class="mt-5"
                >
                  <.card_content>
                    <div class="flex items-center justify-between">
                      <p class="text-sm font-semibold text-fc-text-primary">Bulk results</p>
                      <p class="text-xs text-fc-text-muted">{Enum.count(@bulk_results)} total</p>
                    </div>

                    <div class="mt-3 grid gap-2 cq-card:grid-cols-2 text-xs">
                      <.badge color="success" variant="bordered">
                        {Enum.count(@bulk_results, &(&1.status == :success))} successful
                      </.badge>
                      <.badge color="danger" variant="bordered">
                        {Enum.count(@bulk_results, &(&1.status == :error))} errors
                      </.badge>
                    </div>

                    <div class="mt-4 max-h-64 space-y-2 overflow-y-auto">
                      <.card
                        :for={result <- @bulk_results}
                        variant="bordered"
                        color={if(result.status == :success, do: "success", else: "danger")}
                        rounded="medium"
                        padding="small"
                      >
                        <.card_content>
                          <div class="flex items-center justify-between gap-2">
                            <p class="truncate font-mono text-xs">{result.code}</p>
                            <.icon
                              name={
                                if(result.status == :success, do: "hero-check", else: "hero-x-mark")
                              }
                              class="size-4 shrink-0"
                            />
                          </div>
                          <p class="mt-1 truncate text-xs opacity-80">{result.message}</p>
                        </.card_content>
                      </.card>
                    </div>
                  </.card_content>
                </.card>
              </div>
            </.card_content>
          </.card>
        </section>

        <.card variant="outline" color="natural" rounded="large" padding="large" class="glass-card glass-sheen">
          <.card_content>
            <h2 style="font-size: var(--fc-text-2xl)" class="font-semibold text-fc-text-primary">
              Find attendee
            </h2>

            <p class="mt-2 text-sm text-fc-text-secondary">
              Search by name, email, or ticket code for manual check-ins.
            </p>

            <.form
              id="attendee-search-form"
              for={@search_form}
              phx-change="search_attendees"
              class="mt-5"
            >
              <.input
                field={@search_form[:query]}
                type="search"
                placeholder="Start typing to search attendees"
                autocomplete="off"
                phx-debounce="400"
                data-test="attendee-search-input"
              />
            </.form>

            <p :if={@search_error} class="mt-4 text-sm text-danger-light dark:text-danger-dark">
              {@search_error}
            </p>

            <p :if={@search_loading} class="mt-4 text-sm text-fc-text-secondary">
              Searching attendees...
            </p>

            <div :if={@search_results != []} class="mt-6 space-y-3">
              <.card
                :for={attendee <- @search_results}
                variant="outline"
                color="natural"
                rounded="medium"
                padding="medium"
                class="fc-card-container"
              >
                <.card_content>
                  <div class="flex flex-col gap-3 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
                    <div>
                      <p class="font-semibold text-fc-text-primary">
                        {attendee.first_name} {attendee.last_name}
                      </p>
                      <p class="text-sm text-fc-text-secondary">{attendee.ticket_code}</p>
                      <p class="text-xs text-fc-text-muted">{attendee.ticket_type}</p>
                    </div>

                    <.button
                      type="button"
                      phx-click="manual_check_in"
                      phx-value-ticket_code={attendee.ticket_code}
                      data-test={"manual-check-in-#{attendee.ticket_code}"}
                      color="success"
                      variant="bordered"
                      size="small"
                      disabled={@scans_disabled?}
                    >
                      Check in
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
              class="mt-6 text-sm text-fc-text-secondary"
            >
              No attendees found for "{@search_query}".
            </p>

            <p
              :if={@search_query == "" and not @search_loading and is_nil(@search_error)}
              class="mt-6 text-sm text-fc-text-muted"
            >
              Lookup results will appear here as you type.
            </p>
          </.card_content>
        </.card>

        <.card
          :if={@scan_history != []}
          variant="outline"
          color="natural"
          rounded="large"
          padding="large"
          class="glass-card glass-sheen"
        >
          <.card_content>
            <div class="flex items-center justify-between">
              <h2 class="text-lg font-semibold text-fc-text-primary">Recent scans</h2>

              <.button
                id="clear-scan-history-button"
                type="button"
                phx-click="clear_scan_history"
                variant="bordered"
                color="natural"
                size="extra_small"
              >
                Clear
              </.button>
            </div>

            <div class="mt-4 max-h-64 space-y-2 overflow-y-auto">
              <.card
                :for={scan <- @scan_history}
                variant="bordered"
                color="natural"
                rounded="medium"
                padding="small"
              >
                <.card_content>
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <.icon
                          name={scan_status_icon(scan.status)}
                          class="size-4 text-fc-text-secondary"
                        />
                        <p class="truncate text-sm font-medium text-fc-text-primary">
                          {scan.name || scan.ticket_code}
                        </p>
                        <p class="text-xs text-fc-text-muted">{format_scan_time(scan.scanned_at)}</p>
                      </div>
                      <p class="mt-1 truncate text-xs text-fc-text-secondary">{scan.message}</p>
                    </div>

                    <div class="flex flex-col items-end gap-1">
                      <.badge
                        color={scan_status_color(scan.status)}
                        variant="bordered"
                        size="extra_small"
                      >
                        {scan_status_label(scan.status)}
                      </.badge>
                      <span class="text-xs uppercase text-fc-text-muted">
                        {String.upcase(scan.check_in_type)}
                      </span>
                    </div>
                  </div>
                </.card_content>
              </.card>
            </div>
          </.card_content>
        </.card>

        <div class="pb-6">
          <div class="flex flex-col gap-3 cq-sm:flex-row cq-sm:items-center cq-sm:justify-between">
            <.button_link navigate={~p"/dashboard"} variant="bordered" color="secondary" size="small">
              Back to dashboard
            </.button_link>

            <p class="text-xs text-fc-text-muted">
              {length(@scan_history)} recent scan{if(length(@scan_history) != 1, do: "s", else: "")}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp process_scan(code, socket) do
    if socket.assigns.scans_disabled? do
      message = socket.assigns.scans_disabled_message || "Event archived, scanning disabled"

      {:noreply,
       socket
       |> assign(:last_scan_status, :archived)
       |> assign(:last_scan_result, message)
       |> assign(:last_scan_reason, nil)
       |> assign(:last_scan_checkins_used, 0)
       |> assign(:last_scan_checkins_allowed, 0)
       |> assign(:ticket_code, "")}
    else
      do_process_scan(code, socket)
    end
  end

  defp do_process_scan(code, socket) do
    event_id = socket.assigns.event_id
    entrance_name = socket.assigns.event.entrance_name || "Main Entrance"
    check_in_type = socket.assigns.check_in_type || "entry"
    operator = operator_name(socket)

    case perform_scan_action(event_id, code, check_in_type, entrance_name, operator) do
      {:ok, attendee, _message} ->
        updated_results = update_search_results(socket.assigns.search_results, attendee)
        {allowed, used} = check_in_usage(attendee)

        scan_entry =
          build_scan_history_entry(
            code,
            attendee,
            :success,
            success_message(attendee, check_in_type),
            check_in_type
          )

        # Trigger sound feedback via JavaScript
        socket =
          socket
          |> push_event("scan_result", %{status: "success"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :success,
           last_scan_result: success_message(attendee, check_in_type),
           last_scan_checkins_used: used,
           last_scan_checkins_allowed: allowed,
           last_scan_reason: nil,
           ticket_code: "",
           search_results: updated_results,
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )
         |> apply_optimistic_scan_metrics(check_in_type)
         |> maybe_force_scan_reconcile()}

      {:error, code, message} when code in ["DUPLICATE_TODAY", "DUPLICATE", "ALREADY_INSIDE"] ->
        scan_entry = build_scan_history_entry(code, nil, :duplicate_today, message, check_in_type)

        # Trigger error sound for duplicate
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :duplicate_today,
           last_scan_result: message,
           last_scan_reason: "Already scanned today",
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, "LIMIT_EXCEEDED", message} ->
        scan_entry = build_scan_history_entry(code, nil, :limit_exceeded, message, check_in_type)
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :limit_exceeded,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, "NOT_YET_VALID", message} ->
        scan_entry = build_scan_history_entry(code, nil, :not_yet_valid, message, check_in_type)
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :not_yet_valid,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, "EXPIRED", message} ->
        scan_entry = build_scan_history_entry(code, nil, :expired, message, check_in_type)
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :expired,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, code, message} when code in ["INVALID", "INVALID_TICKET"] ->
        scan_entry = build_scan_history_entry(code, nil, :invalid, message, check_in_type)

        # Trigger error sound for invalid ticket
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :invalid,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, code, message} when code in ["ARCHIVED_EVENT", "SCANS_DISABLED"] ->
        scan_entry = build_scan_history_entry(code, nil, :archived, message, check_in_type)
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :archived,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scans_disabled?: true,
           scans_disabled_message: message,
           event_lifecycle_state:
             if(code == "ARCHIVED_EVENT",
               do: :archived,
               else: socket.assigns.event_lifecycle_state
             ),
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}

      {:error, _code, message} ->
        scan_entry = build_scan_history_entry(code, nil, :error, message, check_in_type)
        socket = push_event(socket, "scan_result", %{status: "error"})

        {:noreply,
         socket
         |> assign(
           last_scan_status: :error,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: "",
           scan_history: add_to_scan_history(socket.assigns.scan_history, scan_entry)
         )}
    end
  end

  defp perform_scan_action(event_id, code, check_in_type, entrance_name, operator) do
    case check_in_type do
      "exit" ->
        Attendees.check_out(event_id, code, entrance_name, operator)

      _ ->
        Attendees.check_in_advanced(event_id, code, "entry", entrance_name, operator)
    end
  end

  # Scan History Helpers

  defp build_scan_history_entry(ticket_code, attendee, status, message, check_in_type) do
    name = if attendee, do: "#{attendee.first_name} #{attendee.last_name}", else: nil
    scanned_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      ticket_code: ticket_code,
      name: name,
      status: status,
      message: message,
      check_in_type: check_in_type,
      scanned_at: scanned_at
    }
  end

  defp add_to_scan_history(history, entry) do
    # Keep only last 10 scans (FIFO)
    [entry | history] |> Enum.take(10)
  end

  defp format_scan_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%H:%M:%S")
    end
  end

  defp scan_status_color(:success), do: "success"
  defp scan_status_color(:duplicate_today), do: "warning"
  defp scan_status_color(:limit_exceeded), do: "danger"
  defp scan_status_color(:not_yet_valid), do: "danger"
  defp scan_status_color(:expired), do: "danger"
  defp scan_status_color(:invalid), do: "danger"
  defp scan_status_color(:error), do: "danger"
  defp scan_status_color(:not_found), do: "danger"
  defp scan_status_color(:already_inside), do: "warning"
  defp scan_status_color(:not_checked_in), do: "danger"
  defp scan_status_color(:archived), do: "natural"
  defp scan_status_color(:invalid_code), do: "danger"
  defp scan_status_color(:invalid_ticket), do: "danger"
  defp scan_status_color(:invalid_entrance), do: "danger"
  defp scan_status_color(:invalid_type), do: "danger"
  defp scan_status_color(:payment_invalid), do: "danger"
  defp scan_status_color(_), do: "natural"

  defp scan_status_label(:success), do: "Success"
  defp scan_status_label(:duplicate_today), do: "Duplicate"
  defp scan_status_label(:limit_exceeded), do: "Limit exceeded"
  defp scan_status_label(:not_yet_valid), do: "Not valid yet"
  defp scan_status_label(:expired), do: "Expired"
  defp scan_status_label(:invalid), do: "Invalid"
  defp scan_status_label(:error), do: "Error"
  defp scan_status_label(:not_found), do: "Not found"
  defp scan_status_label(:already_inside), do: "Already inside"
  defp scan_status_label(:not_checked_in), do: "Not checked in"
  defp scan_status_label(:archived), do: "Archived"
  defp scan_status_label(:invalid_code), do: "Invalid code"
  defp scan_status_label(:invalid_ticket), do: "Invalid ticket"
  defp scan_status_label(:invalid_entrance), do: "Invalid entrance"
  defp scan_status_label(:invalid_type), do: "Invalid type"
  defp scan_status_label(:payment_invalid), do: "Payment invalid"
  defp scan_status_label(_), do: "Unknown"

  defp scan_status_icon(:success), do: "hero-check-circle"
  defp scan_status_icon(:duplicate_today), do: "hero-exclamation-triangle"
  defp scan_status_icon(:limit_exceeded), do: "hero-x-circle"
  defp scan_status_icon(:not_yet_valid), do: "hero-clock"
  defp scan_status_icon(:expired), do: "hero-x-circle"
  defp scan_status_icon(:invalid), do: "hero-x-circle"
  defp scan_status_icon(:error), do: "hero-x-circle"
  defp scan_status_icon(:not_found), do: "hero-x-circle"
  defp scan_status_icon(:already_inside), do: "hero-exclamation-triangle"
  defp scan_status_icon(:not_checked_in), do: "hero-x-circle"
  defp scan_status_icon(:archived), do: "hero-pause-circle"
  defp scan_status_icon(:invalid_code), do: "hero-x-circle"
  defp scan_status_icon(:invalid_ticket), do: "hero-x-circle"
  defp scan_status_icon(:invalid_entrance), do: "hero-x-circle"
  defp scan_status_icon(:invalid_type), do: "hero-x-circle"
  defp scan_status_icon(:payment_invalid), do: "hero-x-circle"
  defp scan_status_icon(_), do: "hero-question-mark-circle"

  defp scan_result_color(:success, "entry"), do: "success"
  defp scan_result_color(:success, "exit"), do: "warning"
  defp scan_result_color(:duplicate_today, _), do: "warning"
  defp scan_result_color(:not_checked_in, _), do: "danger"
  defp scan_result_color(:archived, _), do: "natural"
  defp scan_result_color(:invalid, _), do: "danger"
  defp scan_result_color(:limit_exceeded, _), do: "danger"
  defp scan_result_color(:not_yet_valid, _), do: "danger"
  defp scan_result_color(:expired, _), do: "danger"
  defp scan_result_color(:error, _), do: "danger"
  defp scan_result_color(_, _), do: "natural"

  defp scan_result_title(:success, "entry"), do: "Entry confirmed"
  defp scan_result_title(:success, "exit"), do: "Exit confirmed"
  defp scan_result_title(:duplicate_today, _), do: "Duplicate scan"
  defp scan_result_title(:not_checked_in, _), do: "Cannot check out"
  defp scan_result_title(:limit_exceeded, _), do: "Check-in limit reached"
  defp scan_result_title(:not_yet_valid, _), do: "Ticket not yet valid"
  defp scan_result_title(:expired, _), do: "Ticket expired"
  defp scan_result_title(:invalid, _), do: "Invalid ticket"
  defp scan_result_title(:archived, _), do: "Scanning unavailable"
  defp scan_result_title(:error, _), do: "Scan error"
  defp scan_result_title(_, _), do: "Scan status"

  defp checkins_used_percentage(used, allowed)
       when is_integer(used) and is_integer(allowed) and allowed > 0 do
    trunc(min(used * 100 / allowed, 100))
  end

  defp checkins_used_percentage(_, _), do: 0

  # Safely normalize error codes to known atoms without using String.to_atom/1
  # This avoids atom table exhaustion from arbitrary strings
  @error_code_map %{
    "SUCCESS" => :success,
    "DUPLICATE_TODAY" => :duplicate_today,
    "LIMIT_EXCEEDED" => :limit_exceeded,
    "NOT_YET_VALID" => :not_yet_valid,
    "EXPIRED" => :expired,
    "INVALID" => :invalid,
    "ERROR" => :error,
    "NOT_FOUND" => :not_found,
    "ALREADY_INSIDE" => :already_inside,
    "NOT_CHECKED_IN" => :not_checked_in,
    "SESSION_NOT_FOUND" => :not_checked_in,
    "ARCHIVED" => :archived,
    "INVALID_CODE" => :invalid_code,
    "INVALID_TICKET" => :invalid_ticket,
    "INVALID_ENTRANCE" => :invalid_entrance,
    "INVALID_TYPE" => :invalid_type,
    "PAYMENT_INVALID" => :payment_invalid,
    "TIMEOUT" => :error,
    "UPDATE_FAILED" => :error,
    "TICKET_IN_USE_ELSEWHERE" => :error
  }

  defp normalize_error_code(code) when is_binary(code) do
    Map.get(@error_code_map, String.upcase(code), :error)
  end

  defp assign_event_state(socket) do
    event = Map.get(socket.assigns, :event)

    {state, disabled?, message} =
      case Events.can_check_in?(event) do
        {:ok, lifecycle_state} -> {lifecycle_state, false, nil}
        {:error, {:event_archived, msg}} -> {:archived, true, msg}
        {:error, {_reason, msg}} -> {:unknown, true, msg}
      end

    message_value =
      if disabled? do
        message || Map.get(socket.assigns, :scans_disabled_message) ||
          "Event archived, scanning disabled"
      else
        nil
      end

    socket
    |> assign(:event_lifecycle_state, state)
    |> assign(:scans_disabled?, disabled?)
    |> assign(:scans_disabled_message, message_value)
  end

  defp schedule_event_state_refresh(socket) do
    if connected?(socket) do
      Process.send_after(self(), :refresh_event_state, :timer.minutes(1))
    end

    socket
  end

  defp schedule_stats_reconcile(socket) do
    if connected?(socket) do
      Process.send_after(self(), :reconcile_scanner_metrics, socket.assigns.stats_reconcile_ms)
    end

    socket
  end

  defp scanner_lifecycle_badge_color(:archived), do: "danger"
  defp scanner_lifecycle_badge_color(:grace), do: "warning"
  defp scanner_lifecycle_badge_color(:upcoming), do: "natural"
  defp scanner_lifecycle_badge_color(:unknown), do: "natural"
  defp scanner_lifecycle_badge_color(_), do: "success"

  defp scanner_lifecycle_label(:archived), do: "Archived"
  defp scanner_lifecycle_label(:grace), do: "In grace period"
  defp scanner_lifecycle_label(:upcoming), do: "Upcoming"
  defp scanner_lifecycle_label(:unknown), do: "Status unknown"
  defp scanner_lifecycle_label(_), do: "Active"

  defp update_search_results(search_results, %{} = updated) when is_list(search_results) do
    Enum.map(search_results, fn existing ->
      if Map.get(existing, :ticket_code) == Map.get(updated, :ticket_code),
        do: updated,
        else: existing
    end)
  end

  defp update_search_results(search_results, _), do: search_results

  defp check_in_usage(%{} = attendee) do
    allowed = attendee |> Map.get(:allowed_checkins) |> sanitize_allowed_checkins()
    remaining = attendee |> Map.get(:checkins_remaining) |> sanitize_remaining_checkins()
    used = allowed - min(remaining, allowed)
    {allowed, max(used, 0)}
  end

  defp sanitize_allowed_checkins(value) when is_integer(value) and value > 0, do: value
  defp sanitize_allowed_checkins(_), do: 1

  defp sanitize_remaining_checkins(value) when is_integer(value) and value >= 0, do: value
  defp sanitize_remaining_checkins(_), do: 0

  defp operator_name(socket) do
    socket.assigns
    |> Map.get(:operator_name)
    |> extract_operator_name()
    |> case do
      nil ->
        socket.assigns
        |> Map.get(:current_operator)
        |> extract_operator_name()
        |> case do
          nil ->
            socket.assigns
            |> Map.get(:current_user)
            |> extract_operator_name()

          value ->
            value
        end

      value ->
        value
    end
  end

  defp extract_operator_name(%{} = value) do
    cond do
      is_binary(Map.get(value, :name)) ->
        normalize_name(Map.get(value, :name))

      is_binary(Map.get(value, :full_name)) ->
        normalize_name(Map.get(value, :full_name))

      is_binary(Map.get(value, :first_name)) ->
        parts =
          [
            Map.get(value, :first_name),
            Map.get(value, :last_name) || Map.get(value, :last)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case parts do
          [] -> nil
          list -> Enum.join(list, " ")
        end

      true ->
        nil
    end
  end

  defp extract_operator_name(value) when is_binary(value), do: normalize_name(value)
  defp extract_operator_name(_), do: nil

  defp normalize_name(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp success_message(attendee, "exit"),
    do: "Exit confirmed for #{attendee_first_name(attendee)}."

  defp success_message(attendee, _), do: "Welcome, #{attendee_first_name(attendee)}."

  defp attendee_first_name(%{} = attendee) do
    attendee
    |> Map.get(:first_name)
    |> case do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed != "", do: trimmed, else: attendee_display_name(attendee)

      _ ->
        attendee_display_name(attendee)
    end
  end

  defp attendee_display_name(%{} = attendee) do
    [Map.get(attendee, :first_name), Map.get(attendee, :last_name)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> attendee.email || attendee.ticket_code || "Guest"
      value -> value
    end
  end

  defp parse_event_id(value) when is_integer(value), do: {:ok, value}

  defp parse_event_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> {:ok, int}
      :error -> {:error, :invalid_event_id}
    end
  end

  defp parse_event_id(_), do: {:error, :invalid_event_id}

  defp fetch_event(event_id) do
    {:ok, Events.get_event!(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
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
      |> normalize_percentage_override()
      |> case do
        nil -> calculate_occupancy_percentage(sanitized_count, capacity)
        override -> override
      end

    assign(socket,
      current_occupancy: sanitized_count,
      occupancy_percentage: percentage
    )
  end

  defp derive_capacity_from_socket(socket) do
    socket.assigns
    |> Map.get(:stats)
    |> case do
      %{total: total} -> total
      _ -> nil
    end
    |> case do
      nil -> Map.get(socket.assigns.event, :total_tickets)
      value -> value
    end
  end

  defp sanitize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp sanitize_non_neg_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp sanitize_non_neg_integer(_), do: 0

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

  defp normalize_percentage_override(value) when is_float(value),
    do: Float.round(max(value, 0.0), 1)

  defp normalize_percentage_override(value) when is_integer(value),
    do: normalize_percentage_override(value / 1)

  defp normalize_percentage_override(_), do: nil

  defp apply_optimistic_scan_metrics(socket, check_in_type) do
    current_stats = socket.assigns.stats || %{total: 0, checked_in: 0, pending: 0}
    total = Map.get(current_stats, :total, 0)
    checked_in = Map.get(current_stats, :checked_in, 0)
    pending = Map.get(current_stats, :pending, 0)
    current_occupancy = socket.assigns.current_occupancy || 0
    successful_scan_count = (socket.assigns.successful_scan_count || 0) + 1

    {updated_checked_in, updated_pending, updated_occupancy} =
      case check_in_type do
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

  defp normalize_capacity(value) when is_integer(value) and value > 0, do: value
  defp normalize_capacity(value) when is_float(value) and value > 0, do: trunc(value)
  defp normalize_capacity(_), do: 0

  defp format_percentage(value) when is_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_percentage(_), do: "0.0"

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

  defp entrance_label(nil), do: "General Admission"
  defp entrance_label(""), do: "General Admission"
  defp entrance_label(name), do: name

  defp occupancy_status_color(percentage) when percentage >= 95, do: "danger"
  defp occupancy_status_color(percentage) when percentage > 75, do: "warning"
  defp occupancy_status_color(_), do: "success"

  defp default_camera_permission, do: @default_camera_permission

  defp normalize_camera_permission_status(value) when is_binary(value) do
    case String.downcase(value) do
      "granted" -> :granted
      "denied" -> :denied
      "error" -> :error
      "unsupported" -> :unsupported
      _ -> :unknown
    end
  end

  defp normalize_camera_permission_status(value)
       when value in [:granted, :denied, :error, :unsupported], do: value

  defp normalize_camera_permission_status(_), do: :unknown

  defp normalize_camera_permission_message(value) when value in [nil, ""], do: nil
  defp normalize_camera_permission_message(value) when is_binary(value), do: value
  defp normalize_camera_permission_message(_), do: nil

  defp truthy?(value) when value in [true, 1, "1"], do: true

  defp truthy?(value) when is_binary(value) do
    value_downcased = String.downcase(value)
    value_downcased in ["true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp camera_permission_default_message(:granted),
    do: "Camera access granted. You're ready to scan codes."

  defp camera_permission_default_message(:denied),
    do: "Camera access was denied. Update your browser permissions to scan QR codes."

  defp camera_permission_default_message(:error),
    do: "Something went wrong while trying to access the camera."

  defp camera_permission_default_message(:unsupported),
    do: "This device doesn't expose the camera features required for scanning."

  defp camera_permission_default_message(_),
    do: "Enable the device camera so the QR scanner can stay ready."

  defp camera_permission_status_label(:granted), do: "Camera access granted"
  defp camera_permission_status_label(:denied), do: "Camera access denied"
  defp camera_permission_status_label(:error), do: "Camera error"
  defp camera_permission_status_label(:unsupported), do: "Camera unsupported"
  defp camera_permission_status_label(_), do: "Awaiting camera choice"

  defp camera_permission_badge_color(:granted), do: "success"
  defp camera_permission_badge_color(status) when status in [:denied, :error], do: "danger"
  defp camera_permission_badge_color(:unsupported), do: "warning"
  defp camera_permission_badge_color(_), do: "natural"

  defp camera_permission_alert_kind(:granted), do: :success
  defp camera_permission_alert_kind(status) when status in [:denied, :error], do: :danger
  defp camera_permission_alert_kind(:unsupported), do: :warning
  defp camera_permission_alert_kind(_), do: :natural
end
