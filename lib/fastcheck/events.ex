defmodule FastCheck.Events do
  @moduledoc """
  Context responsible for orchestrating event lifecycle actions such as creation,
  synchronization, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Attendees.Attendee
  alias PetalBlueprint.Repo
  alias FastCheck.{Events.Event, Events.CheckInConfiguration, Attendees}
  alias FastCheck.TickeraClient
  alias Postgrex.Range

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

  @config_fields [
    :ticket_type,
    :ticket_name,
    :allowed_checkins,
    :allow_reentry,
    :allowed_entrances,
    :check_in_window_start,
    :check_in_window_end,
    :check_in_window_timezone,
    :check_in_window_days,
    :check_in_window_buffer_minutes,
    :time_basis,
    :time_basis_timezone,
    :daily_check_in_limit,
    :entrance_limit,
    :limit_per_order,
    :min_per_order,
    :max_per_order,
    :status,
    :message,
    :last_checked_in_date
  ]

  @config_replace_fields (@config_fields ++ [:check_in_window, :updated_at])

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
  Lists every event stored in the database along with aggregated statistics
  such as the number of attendees linked to the event.

  ## Returns
    * list of `%Event{}` structs with the virtual `attendee_count` field
      populated.
  """
  @spec list_events() :: [Event.t()]
  def list_events do
    Event
    |> join(:left, [e], a in Attendee, on: a.event_id == e.id)
    |> group_by([e, _a], e)
    |> select_merge([_e, a], %{attendee_count: count(a.id)})
    |> Repo.all()
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

  @doc """
  Fetches Tickera ticket configurations for an event and upserts them locally.

  Returns the count of configurations inserted/updated or an error tuple when
  credentials are missing or a remote fetch fails.
  """
  @spec fetch_and_store_ticket_configs(integer()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def fetch_and_store_ticket_configs(event_id) when is_integer(event_id) do
    Repo.transaction(fn ->
      case Repo.get(Event, event_id) do
        nil ->
          Repo.rollback("EVENT_NOT_FOUND")

        %Event{} = event ->
          case ensure_event_credentials_present(event) do
            :ok ->
              ticket_type_ids = load_ticket_type_ids(event.id)

              case persist_ticket_configs(event, ticket_type_ids) do
                {:ok, count} ->
                  case touch_last_config_sync(event.id) do
                    :ok -> count
                    {:error, reason} -> Repo.rollback(reason)
                  end

                {:error, reason} ->
                  Repo.rollback(reason)
              end

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, count} ->
        {:ok, count}

      {:error, reason} when reason in ["EVENT_NOT_FOUND", "MISSING_CREDENTIALS", "CONFIG_FETCH_FAILED"] ->
        {:error, reason}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, _} ->
        {:error, "CONFIG_FETCH_FAILED"}
    end
  end

  def fetch_and_store_ticket_configs(_), do: {:error, "INVALID_EVENT"}

  defp ensure_credentials(site_url, api_key) when is_binary(site_url) and is_binary(api_key) do
    case TickeraClient.check_credentials(site_url, api_key) do
      {:ok, _resp} -> :ok
      {:error, _reason} -> {:error, :invalid_credentials}
    end
  end

  defp ensure_credentials(_site_url, _api_key), do: {:error, :invalid_credentials}

  defp ensure_event_credentials_present(%Event{site_url: site_url, api_key: api_key}) do
    if present?(site_url) and present?(api_key) do
      :ok
    else
      Logger.error("Event missing credentials for ticket config sync")
      {:error, "MISSING_CREDENTIALS"}
    end
  end

  defp load_ticket_type_ids(event_id) do
    from(a in Attendee,
      where: a.event_id == ^event_id and not is_nil(a.ticket_type),
      select: a.ticket_type,
      distinct: true
    )
    |> Repo.all()
    |> Enum.reduce([], fn raw, acc ->
      case normalize_ticket_type_id(raw) do
        nil ->
          Logger.debug("Skipping ticket type #{inspect(raw)} for event #{event_id}")
          acc

        id ->
          [id | acc]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_ticket_type_id(value) when is_integer(value) and value > 0, do: value

  defp normalize_ticket_type_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        case Integer.parse(trimmed) do
          {number, _rest} when number > 0 -> number
          _ -> nil
        end
    end
  end

  defp normalize_ticket_type_id(%{} = value) do
    Map.get(value, :ticket_type_id)
    |> case do
      nil -> Map.get(value, "ticket_type_id")
      id -> id
    end
    |> case do
      nil -> nil
      id -> normalize_ticket_type_id(id)
    end
  end

  defp normalize_ticket_type_id(_), do: nil

  defp persist_ticket_configs(%Event{id: event_id} = event, []) do
    Logger.info("No ticket types discovered for event #{event_id}; skipping config sync")
    {:ok, 0}
  end

  defp persist_ticket_configs(%Event{id: event_id} = event, ticket_type_ids) when is_list(ticket_type_ids) do
    ticket_type_ids
    |> Enum.reduce_while({:ok, 0}, fn ticket_type_id, {:ok, count} ->
      case TickeraClient.get_ticket_config(event.site_url, event.api_key, ticket_type_id) do
        {:ok, config} ->
          case upsert_ticket_config(event_id, ticket_type_id, config) do
            {:ok, _record} ->
              Logger.info("Stored ticket config #{ticket_type_id} for event #{event_id}")
              {:cont, {:ok, count + 1}}

            {:error, %Changeset{} = changeset} ->
              Logger.error(
                "Failed to upsert ticket config #{ticket_type_id} for event #{event_id}: #{inspect(changeset.errors)}"
              )

              {:halt, {:error, "CONFIG_FETCH_FAILED"}}
          end

        {:error, code, message} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{code} – #{message}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}

        {:error, reason} ->
          Logger.error(
            "Tickera ticket config fetch failed for event #{event_id} ticket #{ticket_type_id}: #{inspect(reason)}"
          )

          {:halt, {:error, "CONFIG_FETCH_FAILED"}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_ticket_config(event_id, ticket_type_id, config) do
    attrs = build_config_attrs(config, event_id, ticket_type_id)

    %CheckInConfiguration{}
    |> CheckInConfiguration.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, @config_replace_fields},
      conflict_target: [:event_id, :ticket_type_id],
      returning: true
    )
  end

  defp build_config_attrs(config, event_id, ticket_type_id) do
    config
    |> Map.take(@config_fields)
    |> Map.put(:event_id, event_id)
    |> Map.put(:ticket_type_id, ticket_type_id)
    |> normalize_config_dates()
    |> maybe_put_ticket_labels(config)
    |> maybe_put_check_in_window()
  end

  defp normalize_config_dates(attrs) do
    attrs
    |> Map.update(:check_in_window_start, nil, &normalize_date_value/1)
    |> Map.update(:check_in_window_end, nil, &normalize_date_value/1)
    |> Map.update(:last_checked_in_date, nil, &normalize_date_value/1)
  end

  defp maybe_put_ticket_labels(attrs, config) do
    attrs
    |> Map.put(:ticket_type, pick_ticket_label(config, [:ticket_type, :ticket_title, :ticket_name]))
    |> Map.put(:ticket_name, pick_ticket_label(config, [:ticket_name, :ticket_title, :ticket_type]))
  end

  defp pick_ticket_label(config, keys) do
    Enum.find_value(keys, fn key -> presence(Map.get(config, key)) end)
  end

  defp maybe_put_check_in_window(attrs) do
    start_date = Map.get(attrs, :check_in_window_start)
    end_date = Map.get(attrs, :check_in_window_end)

    case build_date_range(start_date, end_date) do
      nil -> attrs
      %Range{} = range -> Map.put(attrs, :check_in_window, range)
    end
  end

  defp build_date_range(nil, nil), do: nil

  defp build_date_range(start_date, end_date) do
    %Range{lower: start_date, upper: end_date, lower_inclusive: true, upper_inclusive: false}
  end

  defp normalize_date_value(nil), do: nil
  defp normalize_date_value(%Date{} = date), do: date
  defp normalize_date_value(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp normalize_date_value(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)

  defp normalize_date_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        case Date.from_iso8601(trimmed) do
          {:ok, date} -> date
          _ -> nil
        end
    end
  end

  defp normalize_date_value(_value), do: nil

  defp touch_last_config_sync(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(e in Event, where: e.id == ^event_id)
    |> Repo.update_all(set: [last_config_sync: now, updated_at: now])
    |> case do
      {1, _} -> :ok
      _ -> {:error, "EVENT_NOT_FOUND"}
    end
  end

  defp present?(value) when is_binary(value), do: presence(value) != nil
  defp present?(_), do: false

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(value), do: value

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
