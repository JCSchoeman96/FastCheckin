defmodule FastCheck.Events do
  @moduledoc """
  Context responsible for orchestrating event lifecycle actions such as creation,
  synchronization, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Attendees.Attendee
  alias FastCheck.{Repo, Events.Event, Attendees}
  alias FastCheck.TickeraClient

  @attr_atom_lookup %{
    "site_url" => :site_url,
    "api_key" => :api_key,
    "name" => :name,
    "status" => :status,
    "entrance_name" => :entrance_name,
    "location" => :location,
    "event_date" => :event_date,
    "event_time" => :event_time
  }

  @doc """
  Creates a new event by validating Tickera credentials, fetching event
  essentials, and persisting the event record.

  ## Parameters
    * `attrs` - map of attributes such as `site_url`, `api_key`, and `name`.

  ## Returns
    * `{:ok, %Event{}}` on success.
    * `{:error, reason}` when validation fails.
    * `{:error, %Ecto.Changeset{}}` when persistence fails.
  """
  @spec create_event(map()) :: {:ok, Event.t()} | {:error, String.t() | Changeset.t()}
  def create_event(attrs) when is_map(attrs) do
    site_url = fetch_attr(attrs, "site_url")
    api_key = fetch_attr(attrs, "api_key")

    with :ok <- ensure_credentials(site_url, api_key),
         {:ok, essentials} <- TickeraClient.get_event_essentials(site_url, api_key),
         event_attrs <- build_event_attrs(attrs, essentials),
         {:ok, %Event{} = event} <- %Event{} |> Event.changeset(event_attrs) |> Repo.insert() do
      Logger.info("Created event #{event.id} for site #{site_url}")
      {:ok, event}
    else
      {:error, :invalid_credentials} ->
        Logger.error("Failed to validate credentials for #{site_url}")
        {:error, "Invalid API key or site URL mismatch"}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        Logger.error("Unable to create event: #{inspect(reason)}")
        {:error, to_string(reason)}
    end
  end

  def create_event(_), do: {:error, "Invalid attributes"}

  @doc """
  Lists every event stored in the database.

  ## Returns
    * list of `%Event{}` structs.
  """
  @spec list_events() :: [Event.t()]
  def list_events do
    Repo.all(Event)
  end

  @doc """
  Retrieves a single event by id, raising `Ecto.NoResultsError` when not found.
  """
  @spec get_event!(integer()) :: Event.t()
  def get_event!(event_id) do
    Repo.get!(Event, event_id)
  end

  @doc """
  Synchronizes attendees for the specified event and updates status timestamps.

  When `progress_callback` is supplied it is invoked for every fetched page with
  `(page, total_pages, count_for_page)`.

  ## Returns
    * `{:ok, message}` when syncing succeeds.
    * `{:error, reason}` if any step fails.
  """
  @spec sync_event(integer(), (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def sync_event(event_id, progress_callback \\ nil) do
    Logger.info("Starting attendee sync for event #{event_id}")

    case Repo.get(Event, event_id) do
      nil ->
        {:error, "Event not found"}

      %Event{} = event ->
        mark_syncing(event)

        callback = wrap_progress_callback(progress_callback)

        case TickeraClient.fetch_all_attendees(event.site_url, event.api_key, 100, callback) do
          {:ok, attendees, total_count} ->
            Logger.info("Fetched #{total_count} attendees for event #{event.id}")

            case Attendees.create_bulk(event.id, attendees) do
              {:ok, inserted_count} ->
                finalize_sync(event)
                count_message = resolve_synced_count(inserted_count, attendees, total_count)
                {:ok, "Synced #{count_message} attendees"}

              {:error, reason} ->
                mark_error(event, reason)
                {:error, format_reason(reason)}
            end

          {:error, reason, _partial} ->
            mark_error(event, reason)
            {:error, format_reason(reason)}
        end
    end
  end

  @doc """
  Fetches an event and refreshes its `checked_in_count` statistic based on the
  number of attendees with a populated `checked_in_at` timestamp.

  ## Returns
    * `%Event{}` with updated `checked_in_count`.
  """
  @spec get_event_with_stats(integer()) :: Event.t()
  def get_event_with_stats(event_id) do
    event = get_event!(event_id)

    checked_in_count =
      from(a in Attendee,
        where: a.event_id == ^event_id and not is_nil(a.checked_in_at),
        select: count(a.id)
      )
      |> Repo.one()

    case event |> Changeset.change(%{checked_in_count: checked_in_count}) |> Repo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("Failed to update stats for event #{event_id}: #{inspect(changeset.errors)}")
        %{event | checked_in_count: checked_in_count}
    end
  end

  defp ensure_credentials(site_url, api_key) when is_binary(site_url) and is_binary(api_key) do
    case TickeraClient.check_credentials(site_url, api_key) do
      {:ok, _resp} -> :ok
      {:error, _reason} -> {:error, :invalid_credentials}
    end
  end

  defp ensure_credentials(_site_url, _api_key), do: {:error, :invalid_credentials}

  defp build_event_attrs(attrs, essentials) do
    event_datetime =
      Map.get(essentials, "event_date_time") ||
        Map.get(essentials, :event_date_time)

    {event_date, event_time} = split_datetime(event_datetime)

    %{
      name:
        fetch_attr(attrs, "name") || Map.get(essentials, "event_name") ||
          Map.get(essentials, :event_name),
      api_key: fetch_attr(attrs, "api_key"),
      site_url: fetch_attr(attrs, "site_url"),
      status: fetch_attr(attrs, "status") || "active",
      entrance_name: fetch_attr(attrs, "entrance_name"),
      location: fetch_attr(attrs, "location"),
      total_tickets: Map.get(essentials, "total_tickets") || Map.get(essentials, :total_tickets),
      event_date: fetch_attr(attrs, "event_date") || event_date,
      event_time: fetch_attr(attrs, "event_time") || event_time
    }
  end

  defp split_datetime(%DateTime{} = datetime) do
    {DateTime.to_date(datetime), DateTime.to_time(datetime)}
  end

  defp split_datetime(%NaiveDateTime{} = datetime) do
    {NaiveDateTime.to_date(datetime), NaiveDateTime.to_time(datetime)}
  end

  defp split_datetime(%Date{} = date), do: {date, nil}
  defp split_datetime(%Time{} = time), do: {nil, time}

  defp split_datetime(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, datetime, _offset} ->
        {DateTime.to_date(datetime), DateTime.to_time(datetime)}

      _ ->
        case NaiveDateTime.from_iso8601(binary) do
          {:ok, naive} ->
            {NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive)}

          _ ->
            {nil, nil}
        end
    end
  end

  defp split_datetime(_), do: {nil, nil}

  defp fetch_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    cond do
      Map.has_key?(attrs, key) ->
        Map.get(attrs, key)

      true ->
        case safe_existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(attrs, atom_key)
        end
    end
  end

  defp fetch_attr(_attrs, _key), do: nil

  defp safe_existing_atom(key) do
    Map.get(@attr_atom_lookup, key)
  end

  defp mark_syncing(event) do
    now = DateTime.utc_now()

    case event
         |> Changeset.change(%{status: "syncing", sync_started_at: now, sync_completed_at: nil})
         |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Unable to mark event #{event.id} as syncing: #{inspect(changeset.errors)}"
        )
    end
  end

  defp finalize_sync(event) do
    now = DateTime.utc_now()

    case event
         |> Changeset.change(%{status: "active", sync_completed_at: now})
         |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "Unable to finalize sync for event #{event.id}: #{inspect(changeset.errors)}"
        )
    end
  end

  defp mark_error(event, reason) do
    event
    |> Changeset.change(%{status: "error"})
    |> Repo.update()

    Logger.error("Sync failed for event #{event.id}: #{format_reason(reason)}")
  end

  defp wrap_progress_callback(nil), do: nil

  defp wrap_progress_callback(callback) when is_function(callback, 3) do
    fn page, total_pages, count ->
      Logger.debug("Sync progress page=#{page}/#{total_pages} count=#{count}")
      safe_callback(callback, page, total_pages, count)
    end
  end

  defp wrap_progress_callback(_), do: nil

  defp safe_callback(callback, page, total_pages, count) do
    try do
      callback.(page, total_pages, count)
    rescue
      exception ->
        Logger.warning("Progress callback error: #{Exception.message(exception)}")
    end
  end

  defp format_reason({:error, reason}), do: format_reason(reason)
  defp format_reason(%Changeset{} = changeset), do: inspect(changeset.errors)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp resolve_synced_count(inserted_count, attendees, total_count) do
    cond do
      is_integer(inserted_count) ->
        inserted_count

      is_map(inserted_count) and Map.has_key?(inserted_count, :count) ->
        Map.get(inserted_count, :count)

      is_map(inserted_count) and Map.has_key?(inserted_count, "count") ->
        Map.get(inserted_count, "count")

      is_map(inserted_count) and Map.has_key?(inserted_count, :inserted) ->
        Map.get(inserted_count, :inserted)

      is_map(inserted_count) and Map.has_key?(inserted_count, "inserted") ->
        Map.get(inserted_count, "inserted")

      is_list(inserted_count) ->
        length(inserted_count)

      is_integer(total_count) ->
        total_count

      true ->
        length(attendees)
    end
  end
end
