defmodule FastCheckWeb.ScannerLive do
  @moduledoc """
  Real-time scanner interface for on-site staff to check in attendees via QR codes.
  """

  use PetalBlueprintWeb, :live_view

  import Phoenix.Component, only: [to_form: 1]

  alias FastCheck.{Attendees, Events}
  alias Phoenix.PubSub
  require Logger

  @default_camera_permission %{status: :unknown, remembered: false, message: nil}

  @impl true
  def mount(%{"event_id" => event_id_param}, _session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, event} <- fetch_event(event_id) do
      stats = Attendees.get_event_stats(event_id)

      socket =
        socket
        |> assign(
          event: event,
          event_id: event_id,
          ticket_code: "",
          last_scan_status: nil,
          last_scan_result: nil,
          stats: stats,
          search_query: "",
          search_results: [],
          search_loading: false,
          search_error: nil,
          camera_permission: default_camera_permission()
        )

      if connected?(socket) do
        PubSub.subscribe(PetalBlueprint.PubSub, event_topic(event_id))
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
     assign(socket, :camera_permission, %{status: status, remembered: remembered, message: message})}
  end

  def handle_event("camera_permission_sync", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:event_stats_updated, event_id, stats}, socket) do
    if socket.assigns.event_id == event_id do
      {:noreply, assign(socket, :stats, stats)}
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

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:scan_form, to_form(%{"ticket_code" => assigns.ticket_code}))
      |> assign(:search_form, to_form(%{"query" => assigns.search_query}))

    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen bg-slate-950 text-white">
        <div class="mx-auto flex min-h-screen max-w-5xl flex-col gap-6 px-4 py-8">
          <header class="rounded-3xl bg-slate-900/80 px-6 py-8 shadow-2xl backdrop-blur">
            <p class="text-sm uppercase tracking-[0.3em] text-slate-400">Event check-in</p>
            <h1 class="mt-2 text-3xl font-semibold text-white sm:text-4xl">{@event.name}</h1>
            <p class="mt-1 text-base text-slate-300">
              Entrance:
              <span class="font-semibold text-white">{entrance_label(@event.entrance_name)}</span>
            </p>
          </header>

          <section class="rounded-3xl bg-slate-800/80 px-6 py-6 shadow-2xl backdrop-blur">
            <div class="grid gap-4 sm:grid-cols-3">
              <div class="rounded-2xl bg-slate-700/70 p-4">
                <p class="text-xs uppercase tracking-widest text-slate-300">Total tickets</p>
                <p class="mt-2 text-3xl font-bold text-white">{@stats.total}</p>
              </div>
              <div class="rounded-2xl bg-green-900/80 p-4">
                <p class="text-xs uppercase tracking-widest text-green-200">Checked in</p>
                <p class="mt-2 text-3xl font-bold text-green-300">{@stats.checked_in}</p>
              </div>
              <div class="rounded-2xl bg-yellow-900/80 p-4">
                <p class="text-xs uppercase tracking-widest text-yellow-200">Pending</p>
                <p class="mt-2 text-3xl font-bold text-yellow-200">{@stats.pending}</p>
              </div>
            </div>

            <div class="mt-5">
              <div class="h-3 w-full rounded-full bg-slate-900/60">
                <div
                  class="h-3 rounded-full bg-gradient-to-r from-green-500 via-emerald-400 to-lime-400 transition-all"
                  style={"width: #{min(@stats.percentage, 100)}%"}
                />
              </div>
              <p class="mt-2 text-sm font-medium text-slate-200">
                {format_percentage(@stats.percentage)}% Checked In
              </p>
            </div>
          </section>

          <section
            :if={@last_scan_status}
            class={scan_status_classes(@last_scan_status)}
            data-test="scan-status"
          >
            <div class="flex items-center gap-4">
              <div class="text-4xl font-bold">{scan_status_icon(@last_scan_status)}</div>
              <p class="text-lg font-semibold leading-tight">{@last_scan_result}</p>
            </div>
            <p class="mt-2 text-sm text-slate-200/80">
              Ready for the next guest – the input is armed for the next scan.
            </p>
          </section>

          <section
            phx-hook="CameraPermission"
            data-storage-key={"fastcheck:camera-permission:event-#{@event_id}"}
            class="rounded-3xl bg-slate-900/85 px-6 py-8 text-white shadow-2xl backdrop-blur"
          >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p class="text-xs uppercase tracking-[0.3em] text-slate-400">Camera status</p>
                <h2 class="mt-1 text-2xl font-semibold">Ready the QR scanner</h2>
                <p class="mt-2 text-sm text-slate-300">
                  We'll remember your choice for this device so future scans start instantly.
                </p>
              </div>
              <span class="rounded-full border border-white/20 px-4 py-1 text-xs uppercase tracking-wide text-slate-100">
                {camera_permission_status_label(@camera_permission.status)}
              </span>
            </div>

            <div class={camera_permission_state_classes(@camera_permission.status)}>
              <p class="text-base font-semibold">
                {camera_permission_status_label(@camera_permission.status)}
              </p>
              <p class="mt-1 text-sm text-slate-100/80">
                {@camera_permission.message || camera_permission_default_message(@camera_permission.status)}
              </p>
            </div>

            <div class="mt-6 flex flex-wrap items-center gap-4">
              <button
                :if={@camera_permission.status != :granted}
                type="button"
                data-camera-request
                class="rounded-2xl bg-emerald-500 px-5 py-3 text-sm font-semibold text-slate-900 shadow-lg transition hover:bg-emerald-400 focus:outline-none focus:ring-4 focus:ring-emerald-300 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-300"
                disabled={@camera_permission.status == :unsupported}
              >
                Enable camera
              </button>

              <p class="text-xs text-slate-400">
                {if @camera_permission.remembered do
                  "Preference synced from this device."
                else
                  "Your decision will be remembered for future check-ins."
                end}
              </p>
            </div>
          </section>

          <section class="rounded-3xl bg-slate-900/90 px-6 py-10 text-white shadow-2xl backdrop-blur">
            <div class="space-y-2 text-center">
              <h2 class="text-2xl font-semibold">Scan tickets</h2>
              <p class="text-sm text-slate-300">
                Use the QR scanner or type a code below. The field stays focused for rapid-fire check-ins.
              </p>
            </div>

            <.form
              :let={f}
              for={@scan_form}
              phx-submit="scan"
              phx-change="update_code"
              class="mx-auto mt-8 max-w-md"
            >
              <.input
                field={f[:ticket_code]}
                type="text"
                placeholder="Point scanner at QR code..."
                autocomplete="off"
                autocorrect="off"
                autocapitalize="characters"
                spellcheck="false"
                inputmode="text"
                autofocus
                aria-label="Ticket code input"
                class="w-full rounded-2xl border-2 border-transparent bg-white px-6 py-5 text-xl font-semibold text-slate-900 shadow-lg focus:border-green-400 focus:outline-none focus:ring-4 focus:ring-green-500"
              />
              <button
                type="submit"
                class="mt-4 w-full rounded-2xl bg-emerald-500 px-6 py-4 text-lg font-semibold text-slate-900 shadow-lg transition hover:bg-emerald-400 focus:outline-none focus:ring-4 focus:ring-emerald-300"
              >
                Process scan
              </button>
            </.form>

            <p class="mt-6 text-center text-sm text-slate-300">
              Or manually enter ticket code
            </p>
          </section>

          <section class="rounded-3xl bg-slate-900/80 px-6 py-8 shadow-2xl backdrop-blur">
            <div class="space-y-2 text-center">
              <h2 class="text-2xl font-semibold">Find attendee</h2>
              <p class="text-sm text-slate-300">
                Search by name, email, or ticket code to handle manual check-ins.
              </p>
            </div>

            <.form
              id="attendee-search-form"
              for={@search_form}
              phx-change="search_attendees"
              class="mx-auto mt-6 max-w-3xl"
            >
              <.input
                field={@search_form[:query]}
                type="search"
                placeholder="Start typing to search attendees..."
                autocomplete="off"
                phx-debounce="400"
                data-test="attendee-search-input"
                class="w-full rounded-2xl border-2 border-transparent bg-slate-800/70 px-6 py-4 text-base text-white shadow-inner shadow-slate-950 focus:border-emerald-400 focus:bg-slate-900/70 focus:outline-none focus:ring-4 focus:ring-emerald-500"
              />
            </.form>

            <p :if={@search_error} class="mt-4 text-center text-sm text-red-300">
              {@search_error}
            </p>

            <p :if={@search_loading} class="mt-4 text-center text-sm text-slate-300">
              Searching attendees...
            </p>

            <ul
              :if={@search_results != []}
              class="mt-6 divide-y divide-slate-800/80 rounded-2xl border border-slate-800/60 bg-slate-900/60"
            >
              <li
                :for={attendee <- @search_results}
                data-test={"search-result-#{attendee.ticket_code}"}
                class="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between"
              >
                <div>
                  <p data-test="attendee-name" class="text-lg font-semibold">
                    {attendee_display_name(attendee)}
                  </p>
                  <p class="text-sm text-slate-300">{attendee.email || "No email provided"}</p>
                  <p :if={attendee.checked_in_at} class="text-xs text-emerald-300">
                    Already checked in
                  </p>
                </div>

                <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
                  <span class="rounded-full bg-slate-800/80 px-3 py-1 text-xs uppercase tracking-wide text-slate-100">
                    {attendee.ticket_type || "Ticket"}
                  </span>
                  <button
                    type="button"
                    class="rounded-2xl bg-emerald-500 px-4 py-2 text-sm font-semibold text-slate-900 transition hover:bg-emerald-400 disabled:cursor-not-allowed disabled:bg-slate-600 disabled:text-slate-200"
                    phx-click="manual_check_in"
                    phx-value-ticket-code={attendee.ticket_code}
                    phx-disable-with="Checking..."
                    disabled={not is_nil(attendee.checked_in_at)}
                    data-test={"manual-check-in-#{attendee.ticket_code}"}
                  >
                    Check in
                  </button>
                </div>
              </li>
            </ul>

            <p
              :if={@search_results == [] and @search_query != "" and not @search_loading and is_nil(@search_error)}
              class="mt-6 text-center text-sm text-slate-300"
            >
              No attendees found. Double-check the spelling and try again.
            </p>

            <p
              :if={@search_query == "" and not @search_loading and is_nil(@search_error)}
              class="mt-6 text-center text-sm text-slate-400"
            >
              Lookup results will appear here as you type.
            </p>
          </section>

          <footer class="mt-auto rounded-3xl bg-slate-800/80 px-6 py-4 text-sm text-slate-300 shadow-2xl">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <a
                href={~p"/dashboard"}
                class="font-semibold text-emerald-300 transition hover:text-emerald-200"
              >
                ← Back to dashboard
              </a>

              <a
                href="#"
                class="font-semibold text-slate-200 opacity-70 transition hover:opacity-100"
              >
                View scan history (coming soon)
              </a>
            </div>
          </footer>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp process_scan(code, socket) do
    event_id = socket.assigns.event_id
    entrance_name = socket.assigns.event.entrance_name || "Main Entrance"

    case Attendees.check_in(event_id, code, entrance_name) do
      {:ok, attendee, _message} ->
        stats = Attendees.get_event_stats(event_id)
        updated_results = update_search_results(socket.assigns.search_results, attendee)

        {:noreply,
         socket
         |> assign(:last_scan_status, :success)
         |> assign(:last_scan_result, "✓ Welcome, #{attendee.first_name} #{attendee.last_name}!")
         |> assign(:stats, stats)
         |> assign(:ticket_code, "")
         |> assign(:search_results, updated_results)}

      {:error, "DUPLICATE", message} ->
        {:noreply,
         socket
         |> assign(:last_scan_status, :duplicate)
         |> assign(:last_scan_result, message)
         |> assign(:ticket_code, "")}

      {:error, "INVALID", message} ->
        {:noreply,
         socket
         |> assign(:last_scan_status, :invalid)
         |> assign(:last_scan_result, message)
         |> assign(:ticket_code, "")}

      {:error, _code, message} ->
        {:noreply,
         socket
         |> assign(:last_scan_status, :error)
         |> assign(:last_scan_result, message)
         |> assign(:ticket_code, "")}
    end
  end
  
  defp update_search_results(search_results, %{} = updated) when is_list(search_results) do
    Enum.map(search_results, fn existing ->
      if Map.get(existing, :ticket_code) == Map.get(updated, :ticket_code), do: updated, else: existing
    end)
  end

  defp update_search_results(search_results, _), do: search_results

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
    {:ok, Events.get_event_with_stats(event_id)}
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp event_topic(event_id), do: "event:#{event_id}:stats"

  defp format_percentage(value) when is_number(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
  end

  defp format_percentage(_), do: "0.0"

  defp entrance_label(nil), do: "General Admission"
  defp entrance_label(""), do: "General Admission"
  defp entrance_label(name), do: name

  defp scan_status_classes(:success),
    do:
      "rounded-3xl border-2 border-green-500 bg-green-900/70 px-6 py-6 text-green-100 shadow-2xl transition"

  defp scan_status_classes(:duplicate),
    do:
      "rounded-3xl border-2 border-yellow-500 bg-yellow-900/70 px-6 py-6 text-yellow-100 shadow-2xl transition"

  defp scan_status_classes(status) when status in [:invalid, :error],
    do:
      "rounded-3xl border-2 border-red-500 bg-red-900/70 px-6 py-6 text-red-100 shadow-2xl transition"

  defp scan_status_classes(_),
    do: "rounded-3xl border-2 border-slate-600 bg-slate-800/80 px-6 py-6 text-slate-100 shadow-2xl"

  defp scan_status_icon(:success), do: "✓"
  defp scan_status_icon(:duplicate), do: "⚠"
  defp scan_status_icon(:invalid), do: "✕"
  defp scan_status_icon(:error), do: "✕"
  defp scan_status_icon(_), do: "ℹ"

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

  defp normalize_camera_permission_status(value) when value in [:granted, :denied, :error, :unsupported], do: value
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

  defp camera_permission_state_classes(:granted),
    do: "mt-6 rounded-2xl border border-emerald-400/60 bg-emerald-500/10 px-5 py-4 text-emerald-100"

  defp camera_permission_state_classes(status) when status in [:denied, :error],
    do: "mt-6 rounded-2xl border border-red-400/60 bg-red-500/10 px-5 py-4 text-red-100"

  defp camera_permission_state_classes(:unsupported),
    do: "mt-6 rounded-2xl border border-yellow-400/60 bg-yellow-500/10 px-5 py-4 text-yellow-100"

  defp camera_permission_state_classes(_),
    do: "mt-6 rounded-2xl border border-slate-700 bg-slate-800/80 px-5 py-4 text-slate-100"
end
