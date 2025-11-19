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

  @impl true
  def mount(%{"event_id" => event_id_param}, _session, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, event} <- fetch_event(event_id) do
      stats = Attendees.get_event_stats(event_id)
      occupancy = Attendees.get_occupancy_breakdown(event_id)
      current_occupancy = Map.get(occupancy, :currently_inside, 0)
      occupancy_percentage = calculate_occupancy_percentage(current_occupancy, stats.total)

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
          search_query: "",
          search_results: [],
          search_loading: false,
          search_error: nil,
          camera_permission: default_camera_permission()
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

  def handle_event("camera_permission_sync", _params, socket) do
    {:noreply, socket}
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
            
            <div class="mt-4 flex flex-wrap gap-3">
              <span class={[
                "inline-flex items-center rounded-full px-4 py-1 text-xs font-semibold uppercase tracking-wide",
                scanner_lifecycle_badge_class(@event_lifecycle_state)
              ]}>
                {scanner_lifecycle_label(@event_lifecycle_state)}
              </span>
            </div>
          </header>
          
          <section
            :if={@scans_disabled?}
            class="rounded-3xl border border-red-500/40 bg-red-900/40 px-6 py-4 text-center text-red-100 shadow-lg"
          >
            <p class="text-lg font-semibold">Scanning disabled</p>
            
            <p class="mt-1 text-sm">
              {@scans_disabled_message || "Event archived, scanning disabled"}
            </p>
          </section>
          
          <section class="rounded-3xl bg-slate-900/85 px-6 py-6 shadow-2xl backdrop-blur">
            <div class="flex flex-col gap-4">
              <div>
                <p class="text-xs uppercase tracking-[0.3em] text-slate-400">Scanner mode</p>
                
                <h2 class="mt-1 text-2xl font-semibold text-white">Entry & exit controls</h2>
                
                <p class="text-sm text-slate-300">
                  Switch the scanner direction instantly while keeping the field focused for rapid-fire processing.
                </p>
              </div>
              
              <div class="flex flex-wrap gap-4 mt-4 mb-6">
                <button
                  phx-click="set_check_in_type"
                  phx-value-type="entry"
                  class={[
                    "px-6 py-3 rounded-lg font-bold text-lg transition-all disabled:cursor-not-allowed disabled:opacity-60",
                    if @check_in_type == "entry" do
                      "bg-green-600 text-white shadow-lg"
                    else
                      "bg-slate-700 text-slate-300"
                    end
                  ]}
                  disabled={@scans_disabled?}
                >
                  ➡️ ENTRY
                </button>
                <button
                  phx-click="set_check_in_type"
                  phx-value-type="exit"
                  class={[
                    "px-6 py-3 rounded-lg font-bold text-lg transition-all disabled:cursor-not-allowed disabled:opacity-60",
                    if @check_in_type == "exit" do
                      "bg-orange-600 text-white shadow-lg"
                    else
                      "bg-slate-700 text-slate-300"
                    end
                  ]}
                  disabled={@scans_disabled?}
                >
                  ⤴️ EXIT
                </button>
              </div>
              
              <div class="mt-2 bg-blue-900 rounded-lg p-6 border-4 border-blue-500">
                <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <p class="text-blue-300 text-sm font-semibold">CURRENT OCCUPANCY</p>
                    
                    <p class="text-6xl font-bold text-blue-200 mt-2">{@current_occupancy}</p>
                    
                    <p class="text-blue-200 text-sm mt-2">Guests inside right now</p>
                  </div>
                  
                  <div class="text-right">
                    <p class="text-blue-300 text-sm">CAPACITY</p>
                    
                    <p class="text-4xl font-bold text-blue-200">
                      {format_percentage(@occupancy_percentage)}%
                    </p>
                    
                    <span class={[
                      "inline-flex items-center justify-center rounded-full px-3 py-1 text-xs font-semibold text-white mt-3",
                      occupancy_status_color(@occupancy_percentage)
                    ]}>
                      Crowd load
                    </span>
                  </div>
                </div>
                
                <div class="mt-4 w-full bg-blue-800 rounded-full h-4 overflow-hidden">
                  <div
                    class="bg-blue-400 h-4 transition-all"
                    style={"width: #{@occupancy_percentage}%"}
                  >
                  </div>
                </div>
              </div>
            </div>
          </section>
          
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
          
          <div
            :if={@last_scan_status}
            id="scan-result"
            phx-remove={JS.add_class("opacity-0", transition: "transition-opacity duration-300")}
          >
            <%= case %{status: @last_scan_status, mode: @check_in_type} do %>
              <% %{status: :success, mode: "entry"} -> %>
                <div class="mt-6 p-8 bg-green-900 border-4 border-green-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-green-300">➡️ ENTERED</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                  
                  <div :if={@last_scan_checkins_allowed > 1}>
                    <p class="text-green-200 text-lg mt-3">
                      Check-in: <span class="font-bold">{@last_scan_checkins_used}</span>
                      of <span class="font-bold">{@last_scan_checkins_allowed}</span>
                      used
                    </p>
                    
                    <div class="mt-3 w-full bg-green-800 rounded-full h-3">
                      <% percentage =
                        div(@last_scan_checkins_used * 100, max(@last_scan_checkins_allowed, 1)) %>
                      <div class="bg-green-400 h-3 rounded-full" style={"width: #{percentage}%"}>
                      </div>
                    </div>
                  </div>
                  
                  <p class="text-green-200 text-sm mt-2">Occupancy: {@current_occupancy} inside</p>
                </div>
              <% %{status: :success, mode: "exit"} -> %>
                <div class="mt-6 p-8 bg-orange-900 border-4 border-orange-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-orange-300">⤴️ EXITED</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                  
                  <p class="text-orange-200 text-sm mt-2">Occupancy: {@current_occupancy} inside</p>
                </div>
              <% %{status: :duplicate_today} -> %>
                <div class="mt-6 p-8 bg-yellow-900 border-4 border-yellow-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-yellow-300">⚠️ DUPLICATE</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                  
                  <p class="text-yellow-200 text-sm mt-2">Next check-in: Tomorrow</p>
                  
                  <p :if={@last_scan_reason} class="text-yellow-100 text-xs mt-1">
                    {@last_scan_reason}
                  </p>
                </div>
              <% %{status: :limit_exceeded} -> %>
                <div class="mt-6 p-8 bg-red-900 border-4 border-red-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-red-300">✖️ LIMIT EXCEEDED</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% %{status: :not_yet_valid} -> %>
                <div class="mt-6 p-8 bg-red-900 border-4 border-red-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-red-300">✖️ NOT YET VALID</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% %{status: :expired} -> %>
                <div class="mt-6 p-8 bg-red-900 border-4 border-red-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-red-300">✖️ EXPIRED</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% %{status: :invalid} -> %>
                <div class="mt-6 p-8 bg-red-900 border-4 border-red-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-red-300">✖️ INVALID</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% %{status: :archived} -> %>
                <div class="mt-6 p-8 bg-slate-900 border-4 border-red-400 rounded-lg text-center shadow-2xl">
                  <p class="text-4xl font-bold text-red-200">⏸️ Scanning disabled</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% %{status: :error} -> %>
                <div class="mt-6 p-8 bg-red-900 border-4 border-red-500 rounded-lg text-center shadow-2xl">
                  <p class="text-6xl font-bold text-red-300">✖️ ERROR</p>
                  
                  <p class="text-white text-2xl mt-3">{@last_scan_result}</p>
                </div>
              <% _ -> %>
                <div class="mt-6 p-8 bg-slate-900 border-4 border-slate-600 rounded-lg text-center shadow-2xl">
                  <p class="text-2xl font-semibold text-white">Ready for the next scan</p>
                </div>
            <% end %>
          </div>
          
          <section
            id="camera-permission-hook"
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
                {@camera_permission.message ||
                  camera_permission_default_message(@camera_permission.status)}
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
                disabled={@scans_disabled?}
              />
              <button
                type="submit"
                class="mt-4 w-full rounded-2xl bg-emerald-500 px-6 py-4 text-lg font-semibold text-slate-900 shadow-lg transition hover:bg-emerald-400 focus:outline-none focus:ring-4 focus:ring-emerald-300 disabled:cursor-not-allowed disabled:opacity-60"
                disabled={@scans_disabled?}
                aria-disabled={@scans_disabled?}
              >
                Process scan
              </button>
            </.form>
            
            <p class="mt-6 text-center text-sm text-slate-300">Or manually enter ticket code</p>
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
            
            <p :if={@search_error} class="mt-4 text-center text-sm text-red-300">{@search_error}</p>
            
            <p :if={@search_loading} class="mt-4 text-center text-sm text-slate-300">
              Searching attendees...
            </p>
            
            <div :if={@search_results != []} class="mt-6 space-y-3">
              <%= for attendee <- @search_results do %>
                <div class="flex items-center justify-between rounded-xl bg-slate-800/80 px-5 py-4 shadow-md backdrop-blur transition hover:bg-slate-700/80">
                  <div>
                    <p class="font-bold text-white">{attendee.first_name} {attendee.last_name}</p>
                    
                    <p class="text-sm text-slate-400">{attendee.ticket_code}</p>
                    
                    <p class="text-xs text-slate-500">{attendee.ticket_type}</p>
                  </div>
                  
                  <button
                    phx-click="manual_check_in"
                    phx-value-ticket_code={attendee.ticket_code}
                    class="rounded-lg bg-emerald-600/20 px-4 py-2 text-sm font-semibold text-emerald-300 hover:bg-emerald-600/30 focus:outline-none focus:ring-2 focus:ring-emerald-500/50"
                    disabled={@scans_disabled?}
                  >
                    Check In
                  </button>
                </div>
              <% end %>
            </div>
            
            <p
              :if={
                @search_results == [] and @search_query != "" and not @search_loading and
                  is_nil(@search_error)
              }
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
                &larr; Back to dashboard
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

    case Attendees.check_in_advanced(event_id, code, check_in_type, entrance_name, operator) do
      {:ok, attendee, _message} ->
        stats = Attendees.get_event_stats(event_id)
        updated_results = update_search_results(socket.assigns.search_results, attendee)
        {allowed, used} = check_in_usage(attendee)

        {:noreply,
         socket
         |> assign(
           last_scan_status: :success,
           last_scan_result: success_message(attendee, check_in_type),
           last_scan_checkins_used: used,
           last_scan_checkins_allowed: allowed,
           last_scan_reason: nil,
           stats: stats,
           ticket_code: "",
           search_results: updated_results
         )}

      {:error, code, message} when code in ["DUPLICATE_TODAY", "DUPLICATE", "ALREADY_INSIDE"] ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :duplicate_today,
           last_scan_result: message,
           last_scan_reason: "Already scanned today",
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: ""
         )}

      {:error, "LIMIT_EXCEEDED", message} ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :limit_exceeded,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: ""
         )}

      {:error, "NOT_YET_VALID", message} ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :not_yet_valid,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0
         )}

      {:error, "EXPIRED", message} ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :expired,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0
         )}

      {:error, code, message} when code in ["INVALID", "INVALID_TICKET"] ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :invalid,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0,
           ticket_code: ""
         )}

      {:error, code, message} when code in ["ARCHIVED_EVENT", "SCANS_DISABLED"] ->
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
             )
         )}

      {:error, _code, message} ->
        {:noreply,
         socket
         |> assign(
           last_scan_status: :error,
           last_scan_result: message,
           last_scan_reason: nil,
           last_scan_checkins_used: 0,
           last_scan_checkins_allowed: 0
         )}
    end
  end

  defp assign_event_state(socket) do
    event = Map.get(socket.assigns, :event)

    {state, disabled?, message} =
      case Events.can_check_in?(event) do
        {:ok, lifecycle_state} -> {lifecycle_state, false, nil}
        {:error, {:event_archived, msg}} -> {:archived, true, msg}
        {:error, {_reason, msg}} -> {:unknown, true, msg || "Scanning disabled"}
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

  defp scanner_lifecycle_badge_class(:archived), do: "bg-red-500/20 text-red-200"
  defp scanner_lifecycle_badge_class(:grace), do: "bg-amber-500/20 text-amber-100"
  defp scanner_lifecycle_badge_class(:upcoming), do: "bg-slate-500/20 text-slate-200"
  defp scanner_lifecycle_badge_class(:unknown), do: "bg-slate-500/20 text-slate-200"
  defp scanner_lifecycle_badge_class(_), do: "bg-emerald-500/20 text-emerald-100"

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

  defp check_in_usage(_), do: {1, 1}

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

  defp success_message(attendee, "exit"), do: "👋 See you soon, #{attendee_first_name(attendee)}!"
  defp success_message(attendee, _), do: "✓ Welcome, #{attendee_first_name(attendee)}!"

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

  defp attendee_first_name(_), do: "Guest"

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

  defp occupancy_status_color(percentage) when percentage >= 100, do: "bg-red-600"
  defp occupancy_status_color(percentage) when percentage > 90, do: "bg-red-500"
  defp occupancy_status_color(percentage) when percentage > 75, do: "bg-yellow-500"
  defp occupancy_status_color(_), do: "bg-green-500"

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

  defp camera_permission_state_classes(:granted),
    do:
      "mt-6 rounded-2xl border border-emerald-400/60 bg-emerald-500/10 px-5 py-4 text-emerald-100"

  defp camera_permission_state_classes(status) when status in [:denied, :error],
    do: "mt-6 rounded-2xl border border-red-400/60 bg-red-500/10 px-5 py-4 text-red-100"

  defp camera_permission_state_classes(:unsupported),
    do: "mt-6 rounded-2xl border border-yellow-400/60 bg-yellow-500/10 px-5 py-4 text-yellow-100"

  defp camera_permission_state_classes(_),
    do: "mt-6 rounded-2xl border border-slate-700 bg-slate-800/80 px-5 py-4 text-slate-100"
end
