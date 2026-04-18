defmodule FastCheckWeb.Components.ScannerComponents do
  @moduledoc """
  Presentation-only components shared by the browser scanner surfaces.
  """

  use Phoenix.Component

  import FastCheckWeb.Components.Badge, only: [badge: 1]
  import FastCheckWeb.Components.Button, only: [button: 1, button_group: 1]
  import FastCheckWeb.Components.Card, only: [card: 1, card_content: 1]
  import FastCheckWeb.Components.Icon, only: [icon: 1]
  import FastCheckWeb.Components.Progress, only: [progress: 1]

  attr :id, :string, required: true
  attr :event_name, :string, required: true
  attr :entrance_label, :string, required: true
  attr :lifecycle_label, :string, required: true
  attr :lifecycle_color, :string, required: true
  attr :operator_name, :string, default: nil
  attr :label, :string, default: "Scanner"
  attr :menu, :boolean, default: false
  attr :class, :string, default: nil
  attr :rest, :global

  def scanner_header(assigns) do
    ~H"""
    <header id={@id} class={["scanner-panel scanner-header", @class]} {@rest}>
      <div class="min-w-0">
        <p class="scanner-eyebrow">{@label}</p>
        <h1 class="scanner-title">{@event_name}</h1>
        <div class="scanner-meta-row">
          <span>{@entrance_label}</span>
          <span :if={@operator_name}>{@operator_name}</span>
        </div>
      </div>

      <div class="scanner-header-actions">
        <.badge color={@lifecycle_color} variant="bordered" rounded="full">
          {@lifecycle_label}
        </.badge>

        <.button
          :if={@menu}
          id="scanner-menu-toggle"
          type="button"
          phx-click="toggle_menu"
          variant="bordered"
          color="natural"
          size="small"
          aria-label="Open scanner menu"
        >
          <.icon name="hero-bars-3" class="size-4" />
        </.button>
      </div>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :check_in_type, :string, required: true
  attr :disabled, :boolean, default: false
  attr :entry_id, :string, default: "entry-mode-button"
  attr :exit_id, :string, default: "exit-mode-button"
  attr :class, :string, default: nil

  def scanner_mode_toggle(assigns) do
    ~H"""
    <.button_group
      id={@id}
      color="natural"
      rounded="large"
      class={class_join(["scanner-mode-toggle", @class])}
    >
      <.button
        id={@entry_id}
        type="button"
        phx-click="set_check_in_type"
        phx-value-type="entry"
        data-check-in-type="entry"
        aria-pressed={@check_in_type == "entry"}
        color={if(@check_in_type == "entry", do: "success", else: "natural")}
        variant={if(@check_in_type == "entry", do: "shadow", else: "bordered")}
        class="w-full"
        disabled={@disabled}
      >
        Entry
      </.button>

      <.button
        id={@exit_id}
        type="button"
        phx-click="set_check_in_type"
        phx-value-type="exit"
        data-check-in-type="exit"
        aria-pressed={@check_in_type == "exit"}
        color={if(@check_in_type == "exit", do: "warning", else: "natural")}
        variant={if(@check_in_type == "exit", do: "shadow", else: "bordered")}
        class="w-full"
        disabled={@disabled}
      >
        Exit
      </.button>
    </.button_group>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true
  attr :check_in_type, :string, required: true
  attr :message, :string, required: true
  attr :reason, :string, default: nil
  attr :checkins_used, :integer, default: 0
  attr :checkins_allowed, :integer, default: 0
  attr :size, :atom, default: :default
  attr :class, :string, default: nil
  attr :rest, :global

  def scan_result_banner(assigns) do
    assigns =
      assigns
      |> assign(:color, scan_result_color(assigns.status, assigns.check_in_type))
      |> assign(:icon, scan_result_icon(assigns.status, assigns.check_in_type))
      |> assign(:title, scan_result_title(assigns.status, assigns.check_in_type))
      |> assign(:padding, scan_result_padding(assigns.size))
      |> assign(:icon_class, scan_result_icon_class(assigns.size))

    ~H"""
    <.card
      id={@id}
      variant="base"
      color={@color}
      rounded="large"
      padding={@padding}
      class={
        class_join([
          "scanner-result-banner fc-scan-pulse",
          @size == :field && "scanner-result-banner--field",
          @class
        ])
      }
      {@rest}
    >
      <.card_content>
        <div class="scanner-result-content">
          <div class="scanner-result-icon">
            <.icon name={@icon} class={@icon_class} />
          </div>

          <div class="min-w-0">
            <p class="scanner-result-title">{@title}</p>
            <p class={[
              "scanner-result-message",
              @size == :compact && "scanner-result-message--compact"
            ]}>
              {@message}
            </p>
            <p :if={@reason} class="scanner-result-reason">{@reason}</p>

            <div
              :if={@status in [:accepted, :success] and @checkins_allowed > 1}
              class="mt-3 space-y-2"
            >
              <p class="text-sm opacity-90">
                Check-ins used: {@checkins_used} of {@checkins_allowed}
              </p>
              <.progress
                value={checkins_used_percentage(@checkins_used, @checkins_allowed)}
                color={@color}
                size="small"
              />
            </div>
          </div>
        </div>
      </.card_content>
    </.card>
    """
  end

  attr :id, :string, required: true
  attr :permission, :map, required: true
  attr :runtime, :map, required: true
  attr :runtime_id, :string, required: true
  attr :class, :string, default: nil

  def camera_status_strip(assigns) do
    permission_status = Map.get(assigns.permission, :status, :unknown)
    runtime_state = Map.get(assigns.runtime, :state, :idle)

    assigns =
      assigns
      |> assign(:permission_status, permission_status)
      |> assign(:runtime_state, runtime_state)
      |> assign(:permission_label, camera_permission_status_label(permission_status))
      |> assign(:runtime_label, camera_runtime_status_label(runtime_state))
      |> assign(:permission_message, camera_permission_message(assigns.permission))
      |> assign(:runtime_message, camera_runtime_message(assigns.runtime))
      |> assign(:runtime_kind, camera_runtime_kind(runtime_state))

    ~H"""
    <div id={@id} class={["scanner-status-strip", @class]}>
      <div class="scanner-status-item">
        <span class={["scanner-status-dot", "scanner-status-dot--#{@permission_status}"]}></span>
        <div>
          <p class="scanner-status-label">{@permission_label}</p>
          <p class="scanner-status-message">{@permission_message}</p>
        </div>
      </div>

      <div id={@runtime_id} class="scanner-status-item" data-test="camera-runtime-status">
        <span class={["scanner-status-dot", "scanner-status-dot--#{@runtime_kind}"]}></span>
        <div>
          <p class="scanner-status-label">{@runtime_label}</p>
          <p class="scanner-status-message">{@runtime_message}</p>
        </div>
      </div>
    </div>
    """
  end

  attr :start_id, :string, required: true
  attr :reconnect_id, :string, required: true
  attr :stop_id, :string, required: true
  attr :runtime, :map, required: true
  attr :scans_disabled, :boolean, default: false
  attr :start_label, :string, default: "Start scanning"
  attr :variant, :atom, default: :default
  attr :class, :string, default: nil

  def camera_action_row(assigns) do
    runtime_state = Map.get(assigns.runtime, :state, :idle)
    recoverable = Map.get(assigns.runtime, :recoverable, true)
    field_variant? = assigns.variant == :field

    assigns =
      assigns
      |> assign(:runtime_state, runtime_state)
      |> assign(:recoverable, recoverable)
      |> assign(:field_variant?, field_variant?)
      |> assign(
        :start_color,
        if(camera_runtime_needs_reconnect?(runtime_state), do: "natural", else: "success")
      )
      |> assign(
        :start_variant,
        if(camera_runtime_needs_reconnect?(runtime_state), do: "bordered", else: "shadow")
      )
      |> assign(:reconnect_color, camera_reconnect_button_color(runtime_state))
      |> assign(:reconnect_variant, camera_reconnect_button_variant(runtime_state))
      |> assign(:stop_color, if(field_variant?, do: "danger", else: "natural"))
      |> assign(:stop_variant, if(field_variant?, do: "shadow", else: "bordered"))
      |> assign(:stop_disabled, if(field_variant?, do: assigns.scans_disabled, else: true))

    ~H"""
    <div class={[
      "scanner-camera-actions",
      @field_variant? && "scanner-camera-actions--field",
      @class
    ]}>
      <.button
        id={@start_id}
        type="button"
        data-qr-start
        color={@start_color}
        variant={@start_variant}
        class={@field_variant? && "scanner-camera-action scanner-camera-action--start"}
        full_width
        disabled={@scans_disabled}
      >
        {@start_label}
      </.button>

      <.button
        id={@reconnect_id}
        type="button"
        data-qr-reconnect
        color={@reconnect_color}
        variant={@reconnect_variant}
        size={if(@field_variant?, do: "small", else: "large")}
        class={@field_variant? && "scanner-camera-action scanner-camera-action--reconnect"}
        full_width
        disabled={!@recoverable or @scans_disabled}
      >
        Reconnect
      </.button>

      <.button
        id={@stop_id}
        type="button"
        data-qr-stop
        variant={@stop_variant}
        color={@stop_color}
        class={@field_variant? && "scanner-camera-action scanner-camera-action--stop"}
        full_width
        disabled={@stop_disabled}
      >
        Stop scanning
      </.button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :scans, :list, required: true
  attr :clear_event, :string, default: nil
  attr :class, :string, default: nil

  def compact_recent_scans(assigns) do
    ~H"""
    <section id={@id} class={["scanner-recent-list", @class]}>
      <div class="scanner-drawer-heading">
        <h2>Recent scans</h2>
        <.button
          :if={@clear_event}
          id="clear-scan-history-button"
          type="button"
          phx-click={@clear_event}
          variant="bordered"
          color="natural"
          size="extra_small"
        >
          Clear
        </.button>
      </div>

      <p :if={@scans == []} class="scanner-empty-state">No scans yet.</p>

      <div :if={@scans != []} class="scanner-recent-items">
        <div :for={scan <- @scans} class="scanner-recent-item">
          <div class="scanner-recent-main">
            <.icon name={scan_status_icon(scan.status)} class="size-4 text-fc-text-secondary" />
            <div class="min-w-0">
              <p class="truncate text-sm font-medium text-fc-text-primary">
                {scan.name || scan.ticket_code}
              </p>
              <p class="truncate text-xs text-fc-text-secondary">{scan.message}</p>
            </div>
          </div>

          <div class="scanner-recent-meta">
            <.badge color={scan_status_color(scan.status)} variant="bordered" size="extra_small">
              {scan_status_label(scan.status)}
            </.badge>
            <span>{format_scan_time(scan.scanned_at)}</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp scan_result_color(:accepted, _), do: "success"
  defp scan_result_color(:success, "entry"), do: "success"
  defp scan_result_color(:success, "exit"), do: "warning"
  defp scan_result_color(:already_used, _), do: "warning"
  defp scan_result_color(:duplicate_today, _), do: "warning"
  defp scan_result_color(:already_inside, _), do: "warning"
  defp scan_result_color(:busy_retry, _), do: "warning"
  defp scan_result_color(:scanner_closed, _), do: "natural"
  defp scan_result_color(:archived, _), do: "natural"
  defp scan_result_color(:invalid_ticket, _), do: "danger"
  defp scan_result_color(:payment_invalid, _), do: "danger"
  defp scan_result_color(:invalid, _), do: "danger"
  defp scan_result_color(:limit_exceeded, _), do: "danger"
  defp scan_result_color(:not_checked_in, _), do: "danger"
  defp scan_result_color(:not_yet_valid, _), do: "danger"
  defp scan_result_color(:expired, _), do: "danger"
  defp scan_result_color(:system_error, _), do: "danger"
  defp scan_result_color(:error, _), do: "danger"
  defp scan_result_color(_, _), do: "natural"

  defp scan_result_title(:accepted, _), do: "Accepted"
  defp scan_result_title(:already_used, _), do: "Already used"
  defp scan_result_title(:success, "entry"), do: "Ticket valid"
  defp scan_result_title(:success, "exit"), do: "Exit confirmed"
  defp scan_result_title(:duplicate_today, _), do: "Already scanned"
  defp scan_result_title(:already_inside, _), do: "Already inside"
  defp scan_result_title(:limit_exceeded, _), do: "No check-ins left"
  defp scan_result_title(:not_checked_in, _), do: "Not checked in"
  defp scan_result_title(:payment_invalid, _), do: "Payment issue"
  defp scan_result_title(:invalid_ticket, _), do: "Invalid ticket"
  defp scan_result_title(:busy_retry, _), do: "Try again"
  defp scan_result_title(:scanner_closed, _), do: "Scanner closed"
  defp scan_result_title(:not_yet_valid, _), do: "Not valid yet"
  defp scan_result_title(:expired, _), do: "Ticket expired"
  defp scan_result_title(:invalid, _), do: "Not valid"
  defp scan_result_title(:archived, _), do: "Scanner closed"
  defp scan_result_title(:system_error, _), do: "System error"
  defp scan_result_title(:error, _), do: "Scan error"
  defp scan_result_title(_, _), do: "Scan status"

  defp scan_result_icon(:accepted, _), do: "hero-check-circle"
  defp scan_result_icon(:success, "entry"), do: "hero-check-circle"
  defp scan_result_icon(:success, "exit"), do: "hero-arrow-left-circle"
  defp scan_result_icon(:already_used, _), do: "hero-exclamation-triangle"
  defp scan_result_icon(:duplicate_today, _), do: "hero-exclamation-triangle"
  defp scan_result_icon(:already_inside, _), do: "hero-exclamation-triangle"
  defp scan_result_icon(:not_checked_in, _), do: "hero-x-circle"
  defp scan_result_icon(:payment_invalid, _), do: "hero-credit-card"
  defp scan_result_icon(:limit_exceeded, _), do: "hero-no-symbol"
  defp scan_result_icon(:invalid_ticket, _), do: "hero-x-circle"
  defp scan_result_icon(:busy_retry, _), do: "hero-arrow-path"
  defp scan_result_icon(:scanner_closed, _), do: "hero-pause-circle"
  defp scan_result_icon(:invalid, _), do: "hero-x-circle"
  defp scan_result_icon(:system_error, _), do: "hero-x-circle"
  defp scan_result_icon(:error, _), do: "hero-x-circle"
  defp scan_result_icon(_, _), do: "hero-question-mark-circle"

  defp scan_result_padding(:compact), do: "medium"
  defp scan_result_padding(_), do: "large"

  defp scan_result_icon_class(:compact), do: "size-6"
  defp scan_result_icon_class(:field), do: "size-10"
  defp scan_result_icon_class(_), do: "size-8"

  defp checkins_used_percentage(used, allowed)
       when is_integer(used) and is_integer(allowed) and allowed > 0 do
    trunc(min(used * 100 / allowed, 100))
  end

  defp checkins_used_percentage(_, _), do: 0

  defp camera_permission_status_label(:granted), do: "Camera ready"
  defp camera_permission_status_label(:denied), do: "Camera blocked"
  defp camera_permission_status_label(:error), do: "Camera error"
  defp camera_permission_status_label(:unsupported), do: "Camera unsupported"
  defp camera_permission_status_label(_), do: "Camera permission needed"

  defp camera_permission_message(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp camera_permission_message(%{status: :denied}), do: "Enable camera access in the browser."
  defp camera_permission_message(%{status: :unsupported}), do: "Use manual scan entry."
  defp camera_permission_message(_), do: "Enable camera to start scanning."

  defp camera_runtime_status_label(:starting), do: "Camera starting"
  defp camera_runtime_status_label(:running), do: "Camera running"
  defp camera_runtime_status_label(:paused), do: "Camera paused"
  defp camera_runtime_status_label(:recovering), do: "Camera reconnecting"
  defp camera_runtime_status_label(:error), do: "Reconnect camera"
  defp camera_runtime_status_label(_), do: "Camera idle"

  defp camera_runtime_message(%{message: message}) when is_binary(message) and message != "",
    do: message

  defp camera_runtime_message(%{state: :running}), do: "Point the QR code at the preview."
  defp camera_runtime_message(%{state: :error}), do: "Reconnect camera or check permission."
  defp camera_runtime_message(_), do: "Start scanning when ready."

  defp camera_runtime_kind(:running), do: :granted
  defp camera_runtime_kind(:paused), do: :warning
  defp camera_runtime_kind(:recovering), do: :warning
  defp camera_runtime_kind(:error), do: :error
  defp camera_runtime_kind(:starting), do: :warning
  defp camera_runtime_kind(_), do: :unknown

  defp camera_runtime_needs_reconnect?(state) when state in [:paused, :recovering, :error],
    do: true

  defp camera_runtime_needs_reconnect?(_), do: false

  defp camera_reconnect_button_color(state) when state in [:paused, :recovering, :error],
    do: "success"

  defp camera_reconnect_button_color(_), do: "natural"

  defp camera_reconnect_button_variant(state) when state in [:paused, :recovering, :error],
    do: "shadow"

  defp camera_reconnect_button_variant(_), do: "bordered"

  defp scan_status_color(status) when status in [:accepted, :success], do: "success"

  defp scan_status_color(status)
       when status in [:already_used, :duplicate_today, :already_inside, :busy_retry],
       do: "warning"

  defp scan_status_color(status) when status in [:scanner_closed, :archived], do: "natural"

  defp scan_status_color(status)
       when status in [
              :limit_exceeded,
              :not_yet_valid,
              :expired,
              :invalid,
              :invalid_ticket,
              :payment_invalid,
              :system_error,
              :error,
              :not_found,
              :not_checked_in,
              :invalid_code,
              :invalid_entrance,
              :invalid_type
            ],
       do: "danger"

  defp scan_status_color(_), do: "natural"

  defp scan_status_label(:accepted), do: "Accepted"
  defp scan_status_label(:success), do: "Valid"
  defp scan_status_label(:already_used), do: "Used"
  defp scan_status_label(:duplicate_today), do: "Duplicate"
  defp scan_status_label(:already_inside), do: "Inside"
  defp scan_status_label(:limit_exceeded), do: "Limit"
  defp scan_status_label(:not_yet_valid), do: "Not valid"
  defp scan_status_label(:expired), do: "Expired"
  defp scan_status_label(:invalid), do: "Invalid"
  defp scan_status_label(:not_found), do: "Missing"
  defp scan_status_label(:not_checked_in), do: "Not inside"
  defp scan_status_label(:scanner_closed), do: "Closed"
  defp scan_status_label(:busy_retry), do: "Retry"
  defp scan_status_label(:system_error), do: "Error"
  defp scan_status_label(:archived), do: "Closed"
  defp scan_status_label(:payment_invalid), do: "Payment"
  defp scan_status_label(:error), do: "Error"
  defp scan_status_label(_), do: "Status"

  defp scan_status_icon(status) when status in [:accepted, :success], do: "hero-check-circle"

  defp scan_status_icon(status) when status in [:already_used, :duplicate_today],
    do: "hero-exclamation-triangle"

  defp scan_status_icon(:not_yet_valid), do: "hero-clock"
  defp scan_status_icon(:already_inside), do: "hero-exclamation-triangle"

  defp scan_status_icon(status) when status in [:scanner_closed, :archived],
    do: "hero-pause-circle"

  defp scan_status_icon(:busy_retry), do: "hero-arrow-path"

  defp scan_status_icon(status)
       when status in [
              :limit_exceeded,
              :expired,
              :invalid,
              :invalid_ticket,
              :payment_invalid,
              :system_error,
              :error,
              :not_found,
              :not_checked_in,
              :invalid_code,
              :invalid_entrance,
              :invalid_type
            ],
       do: "hero-x-circle"

  defp scan_status_icon(_), do: "hero-question-mark-circle"

  defp format_scan_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  rescue
    _ -> "--:--"
  end

  defp format_scan_time(_), do: "--:--"

  defp class_join(classes) do
    classes
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(" ")
  end
end
