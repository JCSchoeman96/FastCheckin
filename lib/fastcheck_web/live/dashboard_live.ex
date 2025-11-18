defmodule FastCheckWeb.DashboardLive do
  @moduledoc """
  Admin dashboard for managing events, launching attendee syncs, and
  monitoring high-level statistics.
  """

  use FastCheckWeb, :live_view

  import Phoenix.Component, only: [to_form: 1]

  alias Ecto.Changeset
  alias FastCheck.Events
  alias FastCheck.Events.Event

  @impl true
  def mount(_params, _session, socket) do
    events = Events.list_events()

    {:ok,
     socket
     |> assign(:events, events)
     |> assign(:selected_event_id, nil)
     |> assign(:show_new_event_form, false)
     |> assign(:sync_progress, nil)
     |> assign(:sync_status, nil)
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
  def handle_event("start_sync", %{"event_id" => event_id_param}, socket) do
    with {:ok, event_id} <- parse_event_id(event_id_param),
         {:ok, _pid} <- start_sync_task(event_id) do
      {:noreply,
       socket
       |> assign(:selected_event_id, event_id)
       |> assign(:sync_progress, {0, 0, 0})
       |> assign(:sync_status, "Starting attendee sync...")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :sync_status, reason)}
    end
  end

  def handle_event("start_sync", _params, socket) do
    {:noreply, assign(socket, :sync_status, "Missing event identifier")}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_progress, page, total, count}, socket) do
    status = progress_status(page, total, count)

    {:noreply,
     socket
     |> assign(:sync_progress, {page, total, count})
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
        status when is_binary(status) and String.starts_with?(status, "Sync failed") -> status
        _ -> "Sync complete!"
      end

    {:noreply,
     socket
     |> assign(:events, refreshed_events)
     |> assign(:sync_progress, nil)
     |> assign(:sync_status, final_status)
     |> assign(:selected_event_id, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-7xl space-y-8 px-4 py-10">
        <div class="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          <div>
            <p class="text-sm uppercase tracking-widest text-slate-500">Control Center</p>
            <h1 class="text-3xl font-semibold text-slate-900">FastCheck Dashboard</h1>
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
            <.input field={@form[:name]} type="text" label="Event name" placeholder="Tech Summit 2024" />
            <.input field={@form[:tickera_site_url]} type="text" label="Site URL" placeholder="https://example.com" />
            <.input field={@form[:tickera_api_key_encrypted]} type="password" label="Tickera API Key" placeholder="••••••" />
            <.input field={@form[:location]} type="text" label="Location" placeholder="Cape Town Convention Centre" />
            <.input field={@form[:entrance_name]} type="text" label="Entrance Name" placeholder="Main Gate" />

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
          <div class="flex items-center justify-between">
            <h2 class="text-2xl font-semibold text-slate-900">Events</h2>
            <p class="text-sm text-slate-500">Manage entrances, sync attendees, and launch scanners.</p>
          </div>

          <div class="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
            <div
              :for={event <- @events}
              class={[
                "rounded-2xl border border-slate-200 bg-white p-6 shadow transition hover:-translate-y-1 hover:shadow-lg",
                @selected_event_id == event.id && "ring-2 ring-blue-500"
              ]}
            >
              <div class="flex items-start justify-between">
                <div>
                  <p class="text-sm uppercase tracking-wide text-slate-400">{event.location || "Unassigned"}</p>
                  <h3 class="mt-1 text-xl font-semibold text-slate-900">{event.name}</h3>
                </div>
                <span class="rounded-full bg-blue-50 px-3 py-1 text-xs font-semibold text-blue-700">
                  {event.entrance_name || "Entrance"}
                </span>
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
                <button
                  type="button"
                  class="flex-1 rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow hover:bg-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
                  phx-click="start_sync"
                  phx-value-event_id={event.id}
                  phx-disable-with="Syncing..."
                >
                  Sync attendees
                </button>

                <a
                  href={"/scan/#{event.id}"}
                  class="flex-1 rounded-md border border-slate-200 px-4 py-2 text-center text-sm font-semibold text-slate-700 transition hover:border-slate-300 hover:text-slate-900"
                >
                  Open scanner
                </a>
              </div>
            </div>

            <div :if={Enum.empty?(@events)} class="col-span-full rounded-2xl border border-dashed border-slate-300 p-10 text-center">
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

  defp parse_event_id(event_id) when is_integer(event_id), do: {:ok, event_id}

  defp parse_event_id(event_id) when is_binary(event_id) do
    case Integer.parse(event_id) do
      {value, _} -> {:ok, value}
      :error -> {:error, "Invalid event identifier"}
    end
  end

  defp parse_event_id(_), do: {:error, "Invalid event identifier"}

  defp start_sync_task(event_id) do
    parent = self()

    Task.start_link(fn ->
      result =
        Events.sync_event(event_id, fn page, total, count ->
          send(parent, {:sync_progress, page, total, count})
        end)

      case result do
        {:error, reason} -> send(parent, {:sync_error, format_error(reason)})
        _ -> :ok
      end

      send(parent, :sync_complete)
    end)
  end

  defp progress_status(page, total, count) do
    cond do
      total in [nil, 0] -> "Syncing attendees..."
      true -> "Syncing attendees (page #{page}/#{total}) • Imported #{count} records"
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

  defp format_error(%Changeset{} = changeset) do
    changeset
    |> Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, messages} -> "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", " )}" end)
    |> Enum.join(". ")
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
