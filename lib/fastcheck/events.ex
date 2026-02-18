defmodule FastCheck.Events do
  @moduledoc """
  Context responsible for orchestrating event lifecycle actions such as creation,
  synchronization, and reporting.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Changeset
  alias FastCheck.Attendees.{Attendee, CheckIn}
  alias FastCheck.Repo

  alias FastCheck.{
    Attendees,
    Crypto,
    Events.Event,
    Events.Cache,
    Events.Config,
    Events.Sync
  }

  alias FastCheck.TickeraClient
  alias FastCheck.Cache.EtsLayer
  alias Plug.Crypto, as: PlugCrypto

  @attr_atom_lookup %{
    "site_url" => :site_url,
    "tickera_site_url" => :tickera_site_url,
    "api_key" => :api_key,
    "tickera_api_key_encrypted" => :tickera_api_key_encrypted,
    "tickera_api_key_last4" => :tickera_api_key_last4,
    "mobile_access_code" => :mobile_access_code,
    "mobile_access_secret_encrypted" => :mobile_access_secret_encrypted,
    "name" => :name,
    "status" => :status,
    "entrance_name" => :entrance_name,
    "location" => :location,
    "event_date" => :event_date,
    "event_time" => :event_time,
    "tickera_start_date" => :tickera_start_date,
    "tickera_end_date" => :tickera_end_date,
    "last_sync_at" => :last_sync_at,
    "last_soft_sync_at" => :last_soft_sync_at
  }

  @credential_fields [
    :site_url,
    :tickera_site_url,
    :tickera_api_key_encrypted,
    :tickera_api_key_last4,
    :mobile_access_secret_encrypted,
    :tickera_start_date,
    :tickera_end_date,
    :status
  ]

  @seconds_per_day 86_400

  @doc """
  Warm up ETS cache for a given event.

  Loads attendees and entrances into ETS for ultra-fast lookup.
  This does NOT change existing query behavior yet – it's preparatory.
  """
  def warm_event_cache(%Event{id: event_id}) do
    attendees = Attendees.list_event_attendees(event_id)
    entrances = list_entrances(event_id)

    EtsLayer.put_attendees(event_id, attendees)
    EtsLayer.put_entrances(event_id, entrances)

    :ok
  end

  defp list_entrances(event_id) when is_integer(event_id) do
    case EtsLayer.list_entrances(event_id) do
      [] ->
        entrances =
          [event_entrance_name(event_id) | fetch_distinct_entrance_names(event_id)]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> MapSet.new()
          |> Enum.map(fn name -> %{id: name, entrance_name: name} end)

        EtsLayer.put_entrances(event_id, entrances)

        entrances

      entrances ->
        entrances
    end
  end

  defp event_entrance_name(event_id) do
    case Repo.get(Event, event_id) do
      %Event{entrance_name: name} -> name
      _ -> nil
    end
  end

  defp fetch_distinct_entrance_names(event_id) do
    attendee_entrances =
      from(a in Attendee,
        where: a.event_id == ^event_id and not is_nil(a.last_entrance) and a.last_entrance != "",
        select: a.last_entrance
      )
      |> Repo.all()

    check_in_entrances =
      from(ci in CheckIn,
        where:
          ci.event_id == ^event_id and not is_nil(ci.entrance_name) and ci.entrance_name != "",
        select: ci.entrance_name
      )
      |> Repo.all()

    attendee_entrances ++ check_in_entrances
  end

  @doc """
  Determines an event's lifecycle state using its Tickera start and end dates
  plus the configured post-event grace period.
  """
  @spec event_lifecycle_state(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          :unknown | :upcoming | :active | :grace | :archived
  def event_lifecycle_state(event, reference_datetime \\ DateTime.utc_now())

  def event_lifecycle_state(%Event{} = event, reference_datetime) do
    now = normalize_reference_datetime(reference_datetime)
    start_time = normalize_event_datetime(event.tickera_start_date)
    end_time = normalize_event_datetime(event.tickera_end_date)
    grace_cutoff = grace_period_end(end_time)

    cond do
      is_nil(now) ->
        :unknown

      is_nil(start_time) and is_nil(end_time) ->
        :unknown

      not is_nil(start_time) and NaiveDateTime.compare(now, start_time) == :lt ->
        :upcoming

      is_nil(end_time) ->
        :active

      NaiveDateTime.compare(now, end_time) in [:lt, :eq] ->
        :active

      not is_nil(grace_cutoff) and NaiveDateTime.compare(now, grace_cutoff) in [:lt, :eq] ->
        :grace

      true ->
        :archived
    end
  end

  def event_lifecycle_state(_, _), do: :unknown

  @doc """
  Returns `{:ok, state}` when syncing is allowed or `{:error, {:event_archived, message}}`
  when the event has moved beyond the grace period.
  """
  @spec can_sync_event?(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          {:ok, atom()} | {:error, {:event_archived, String.t()} | {:event_missing, String.t()}}
  def can_sync_event?(event, reference_datetime \\ DateTime.utc_now())

  def can_sync_event?(%Event{} = event, reference_datetime) do
    case event_lifecycle_state(event, reference_datetime) do
      :archived -> {:error, {:event_archived, "Event archived, sync disabled"}}
      state -> {:ok, state}
    end
  end

  def can_sync_event?(_, _), do: {:error, {:event_missing, "Event not available"}}

  @doc """
  Returns `{:ok, state}` when check-ins are permitted or `{:error, {:event_archived, message}}`
  when the event is archived.
  """
  @spec can_check_in?(Event.t() | nil, DateTime.t() | NaiveDateTime.t() | nil) ::
          {:ok, atom()} | {:error, {:event_archived, String.t()} | {:event_missing, String.t()}}
  def can_check_in?(event, reference_datetime \\ DateTime.utc_now())

  def can_check_in?(%Event{} = event, reference_datetime) do
    case event_lifecycle_state(event, reference_datetime) do
      :archived -> {:error, {:event_archived, "Event archived, scanning disabled"}}
      state -> {:ok, state}
    end
  end

  def can_check_in?(_, _), do: {:error, {:event_missing, "Event not available"}}

  # Delegation Functions (Backwards Compatibility)

  @doc "Lists all cached events."
  @spec list_events() :: [Event.t()]
  defdelegate list_events(), to: Cache

  @doc "Fetches an event by ID, raises if not found."
  @spec get_event!(integer()) :: Event.t()
  defdelegate get_event!(event_id), to: Cache

  @doc "Synchronizes attendees for the specified event."
  @spec sync_event(
          integer(),
          (pos_integer(), pos_integer(), non_neg_integer() -> any()) | nil,
          keyword()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate sync_event(event_id, progress_callback \\ nil, opts \\ []), to: Sync

  @doc "Returns event with refreshed stats."
  @spec get_event_with_stats(integer()) :: Event.t()
  defdelegate get_event_with_stats(event_id), to: FastCheck.Events.Stats

  @doc "Returns cached event statistics."
  @spec get_event_stats(integer()) :: map()
  defdelegate get_event_stats(event_id), to: FastCheck.Events.Stats

  @doc "Updates occupancy count."
  @spec update_occupancy(integer(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate update_occupancy(event_id, delta), to: FastCheck.Events.Stats

  @doc "Returns advanced event statistics."
  @spec get_event_advanced_stats(integer()) :: map()
  defdelegate get_event_advanced_stats(event_id), to: FastCheck.Events.Stats

  @doc "Lists recent sync logs for an event."
  @spec list_event_sync_logs(integer(), integer()) :: [FastCheck.Events.SyncLog.t()]
  defdelegate list_event_sync_logs(event_id, limit \\ 10), to: FastCheck.Events.SyncLog

  @doc "Broadcasts occupancy update."
  @spec broadcast_occupancy_update(integer(), integer()) :: :ok
  defdelegate broadcast_occupancy_update(event_id, delta), to: FastCheck.Events.Stats

  @doc "Fetches and stores ticket configurations."
  @spec fetch_and_store_ticket_configs(integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate fetch_and_store_ticket_configs(event_id), to: Config

  @doc """
  Creates a new event by validating Tickera credentials, fetching event
  essentials, and persisting the event record.

  ## Parameters
    * `attrs` - map of attributes such as `tickera_site_url`,
      `tickera_api_key_encrypted`, and `name`.

  ## Returns
    * `{:ok, %Event{}}` on success.
    * `{:error, reason}` when validation fails.
    * `{:error, %Ecto.Changeset{}}` when persistence fails.
  """
  @spec create_event(map()) :: {:ok, Event.t()} | {:error, String.t() | Changeset.t()}
  def create_event(attrs) when is_map(attrs) do
    site_url = fetch_attr(attrs, "tickera_site_url") || fetch_attr(attrs, "site_url")

    api_key =
      fetch_attr(attrs, "tickera_api_key_encrypted") ||
        fetch_attr(attrs, "api_key")

    mobile_access_code =
      fetch_attr(attrs, "mobile_access_code") || fetch_attr(attrs, "mobile_access_secret")

    with :ok <- ensure_credentials(site_url, api_key),
         {:ok, essentials} <- TickeraClient.get_event_essentials(site_url, api_key),
         {:ok, {start_date, end_date}} <- {:ok, resolve_tickera_window(attrs, essentials)},
         {:ok, credential_struct} <-
           set_tickera_credentials(%Event{}, site_url, api_key, start_date, end_date),
         {:ok, credential_struct} <-
           set_mobile_access_secret(credential_struct, mobile_access_code),
         credential_attrs <- credential_attrs_from_struct(credential_struct),
         event_attrs <- credential_attrs |> Map.merge(build_event_attrs(attrs, essentials)),
         {:ok, %Event{} = event} <- %Event{} |> Event.changeset(event_attrs) |> Repo.insert() do
      Logger.info("Created event #{event.id} for site #{site_url}")
      _ = Cache.persist_event_cache(event)
      Cache.invalidate_events_list_cache()
      {:ok, event}
    else
      {:error, :invalid_credentials} ->
        Logger.error("Failed to validate credentials for #{site_url}")
        {:error, "Invalid API key or site URL mismatch"}

      {:error, %Changeset{} = changeset} ->
        {:error, changeset}

      {:error, :encryption_failed} ->
        Logger.error("Unable to store credentials for #{site_url}: encryption failed")
        {:error, "Unable to store Tickera credentials"}

      {:error, :invalid_mobile_secret} ->
        {:error, "Mobile access code can't be blank"}

      {:error, reason} ->
        Logger.error("Unable to create event: #{inspect(reason)}")
        {:error, credential_error_message(reason)}
    end
  end

  def create_event(_), do: {:error, "Invalid attributes"}

  @doc """
  Archives an event by setting its status to "archived".

  Archived events cannot be synced or scanned.

  ## Parameters
    * `event_id` - The integer ID of the event to archive

  ## Returns
    * `{:ok, %Event{}}` on success
    * `{:error, reason}` when the event is not found or update fails
  """
  @spec archive_event(integer()) :: {:ok, Event.t()} | {:error, term()}
  def archive_event(event_id) when is_integer(event_id) and event_id > 0 do
    case Cache.get_event!(event_id) do
      %Event{status: "archived"} = event ->
        {:ok, event}

      %Event{} = event ->
        event
        |> Event.changeset(%{status: "archived"})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Cache.invalidate_event_cache(updated.id)
            Cache.invalidate_events_list_cache()
            Logger.info("Archived event #{event_id}")
            {:ok, updated}

          {:error, reason} ->
            Logger.error("Failed to archive event #{event_id}: #{inspect(reason)}")
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def archive_event(_), do: {:error, :invalid_event_id}

  @doc """
  Unarchives an event by setting its status to "active".

  ## Parameters
    * `event_id` - The integer ID of the event to unarchive

  ## Returns
    * `{:ok, %Event{}}` on success
    * `{:error, reason}` when the event is not found or update fails
  """
  @spec unarchive_event(integer()) :: {:ok, Event.t()} | {:error, term()}
  def unarchive_event(event_id) when is_integer(event_id) and event_id > 0 do
    case Cache.get_event!(event_id) do
      %Event{status: "active"} = event ->
        {:ok, event}

      %Event{} = event ->
        event
        |> Event.changeset(%{status: "active"})
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            Cache.invalidate_event_cache(updated.id)
            Cache.invalidate_events_list_cache()
            Logger.info("Unarchived event #{event_id}")
            {:ok, updated}

          {:error, reason} ->
            Logger.error("Failed to unarchive event #{event_id}: #{inspect(reason)}")
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def unarchive_event(_), do: {:error, :invalid_event_id}

  @doc """
  Updates an existing event with new attributes.

  Only updates fields that are provided. API key validation is only performed
  if the API key is being changed.

  ## Parameters
    * `event_id` - The integer ID of the event to update
    * `attrs` - Map of attributes to update (name, location, entrance_name, etc.)

  ## Returns
    * `{:ok, %Event{}}` on success
    * `{:error, reason}` when the event is not found or update fails
  """
  @spec update_event(integer(), map()) :: {:ok, Event.t()} | {:error, term()}
  def update_event(event_id, attrs) when is_integer(event_id) and event_id > 0 do
    case Cache.get_event!(event_id) do
      %Event{} = event ->
        # Only validate API key if it's being changed
        attrs =
          if Map.has_key?(attrs, "tickera_api_key_encrypted") || Map.has_key?(attrs, "api_key") do
            # API key is being updated, validate credentials
            site_url = Map.get(attrs, "tickera_site_url") || event.tickera_site_url
            api_key = Map.get(attrs, "tickera_api_key_encrypted") || Map.get(attrs, "api_key")

            if site_url && api_key do
              case ensure_credentials(site_url, api_key) do
                :ok ->
                  attrs

                {:error, reason} ->
                  Map.put(attrs, :_validation_error, credential_error_message(reason))
              end
            else
              attrs
            end
          else
            attrs
          end

        if Map.has_key?(attrs, :_validation_error) do
          {:error, Map.get(attrs, :_validation_error)}
        else
          # Prepare update attributes
          update_attrs = prepare_update_attrs(attrs, event)

          event
          |> Event.changeset(update_attrs)
          |> Repo.update()
          |> case do
            {:ok, updated} ->
              Cache.invalidate_event_cache(updated.id)
              Cache.invalidate_events_list_cache()
              Logger.info("Updated event #{event_id}")
              {:ok, updated}

            {:error, reason} ->
              Logger.error("Failed to update event #{event_id}: #{inspect(reason)}")
              {:error, reason}
          end
        end

      nil ->
        {:error, :not_found}
    end
  end

  def update_event(_, _), do: {:error, :invalid_event_id}

  defp prepare_update_attrs(attrs, event) do
    attrs
    |> Map.drop([:_validation_error])
    |> normalize_site_url_attrs(event)
    |> maybe_encrypt_api_key(event)
    |> maybe_update_last4(event)
  end

  defp normalize_site_url_attrs(attrs, event) do
    site_url =
      Map.get(attrs, "tickera_site_url") ||
        Map.get(attrs, "site_url") ||
        event.tickera_site_url ||
        event.site_url

    if present_binary?(site_url) do
      trimmed = String.trim(site_url)

      attrs
      |> Map.put("tickera_site_url", trimmed)
      |> Map.put("site_url", trimmed)
    else
      attrs
    end
  end

  defp maybe_encrypt_api_key(attrs, _event) do
    api_key = Map.get(attrs, "tickera_api_key_encrypted") || Map.get(attrs, "api_key")

    if api_key && is_binary(api_key) && api_key != "" do
      # New API key provided, encrypt it
      case Crypto.encrypt(api_key) do
        {:ok, encrypted} ->
          # Extract last4 from the original key
          last4 = String.slice(api_key, -4, 4)

          attrs
          |> Map.put("tickera_api_key_encrypted", encrypted)
          |> Map.put("tickera_api_key_last4", last4)

        _ ->
          attrs
      end
    else
      # No API key provided, keep existing
      attrs
      |> Map.delete("tickera_api_key_encrypted")
      |> Map.delete("api_key")
    end
  end

  defp maybe_update_last4(attrs, event) do
    # If we're updating the API key, last4 is already set in maybe_encrypt_api_key
    # Otherwise, keep existing last4
    if Map.has_key?(attrs, "tickera_api_key_last4") do
      attrs
    else
      Map.put(attrs, "tickera_api_key_last4", event.tickera_api_key_last4)
    end
  end

  @doc """
  Lists cached events along with their attendee counts, falling back to the
  database when the cache is cold.

  The result is cached for 15 minutes using the `"events:all"` key so
  successive dashboard loads stay under the 50ms target.

  ## Examples
  Encrypts and persists Tickera credentials for the provided event.

  When called with a new `%Event{}` struct, the encrypted attributes are returned on
  the struct so they can be merged into a changeset prior to insert.
  """
  @spec set_tickera_credentials(
          Event.t(),
          String.t(),
          String.t(),
          DateTime.t() | NaiveDateTime.t() | Date.t() | String.t() | nil,
          DateTime.t() | NaiveDateTime.t() | Date.t() | String.t() | nil
        ) :: {:ok, Event.t()} | {:error, term()}
  def set_tickera_credentials(%Event{} = event, site_url, api_key, start_date, end_date)
      when is_binary(site_url) and is_binary(api_key) do
    normalized_site_url = String.trim(site_url)
    start_datetime = coerce_event_datetime(start_date)
    end_datetime = coerce_event_datetime(end_date)

    with {:ok, encrypted} <- Crypto.encrypt(api_key),
         attrs <-
           %{
             site_url: normalized_site_url,
             tickera_site_url: normalized_site_url,
             tickera_api_key_encrypted: encrypted,
             tickera_api_key_last4: derive_last4(api_key),
             tickera_start_date: start_datetime,
             tickera_end_date: end_datetime,
             status: "active"
           } do
      apply_credential_attrs(event, attrs)
    end
  end

  def set_tickera_credentials(_event, _site_url, _api_key, _start_date, _end_date),
    do: {:error, :invalid_credentials}

  @doc """
  Encrypts and stores the per-event mobile access credential.

  Returns the updated event or an error when the credential is blank or encryption fails.
  """
  @spec set_mobile_access_secret(Event.t(), String.t()) :: {:ok, Event.t()} | {:error, term()}
  def set_mobile_access_secret(%Event{} = event, secret) when is_binary(secret) do
    case String.trim(secret) do
      "" ->
        {:error, :invalid_mobile_secret}

      trimmed ->
        with {:ok, encrypted} <- Crypto.encrypt(trimmed) do
          apply_credential_attrs(event, %{mobile_access_secret_encrypted: encrypted})
        end
    end
  end

  def set_mobile_access_secret(_event, _secret), do: {:error, :invalid_mobile_secret}

  @doc """
  Validates a provided credential against the stored encrypted value.
  """
  @spec verify_mobile_access_secret(Event.t(), String.t()) ::
          :ok | {:error, :missing_secret | :invalid_credential | :missing_credential}
  def verify_mobile_access_secret(%Event{} = event, credential) when is_binary(credential) do
    trimmed = String.trim(credential)

    cond do
      trimmed == "" ->
        {:error, :missing_credential}

      is_nil(event.mobile_access_secret_encrypted) ->
        {:error, :missing_secret}

      true ->
        with {:ok, stored} <- Crypto.decrypt(event.mobile_access_secret_encrypted),
             true <- secure_compare?(stored, trimmed) do
          :ok
        else
          {:error, reason} ->
            Logger.warning(fn ->
              {"failed to decrypt mobile access secret",
               event_id: event.id, reason: inspect(reason)}
            end)

            {:error, :invalid_credential}

          false ->
            {:error, :invalid_credential}
        end
    end
  end

  def verify_mobile_access_secret(_event, _credential), do: {:error, :missing_credential}

  @doc """
  Decrypts the stored Tickera API key for the event.
  """
  @spec get_tickera_api_key(Event.t() | nil) :: {:ok, String.t()} | {:error, :decryption_failed}
  defdelegate get_tickera_api_key(event), to: Sync

  @doc """
  Updates `last_sync_at` to the current timestamp for the event.
  """
  @spec touch_last_sync(integer()) :: :ok | {:error, term()}
  defdelegate touch_last_sync(event_id), to: Sync

  @doc """
  Updates `last_soft_sync_at` to the current timestamp for the event.
  """
  @spec touch_last_soft_sync(integer()) :: :ok | {:error, term()}
  defdelegate touch_last_soft_sync(event_id), to: Sync

  defp secure_compare?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and PlugCrypto.secure_compare(left, right)
  end

  defp secure_compare?(_left, _right), do: false

  defp derive_last4(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      start = max(String.length(trimmed) - 4, 0)
      String.slice(trimmed, start, 4)
    end
  end

  defp derive_last4(_), do: nil

  defp credential_attrs_from_struct(%Event{} = event) do
    event
    |> Map.take(@credential_fields)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp apply_credential_attrs(%Event{} = event, attrs) do
    case event.__meta__.state do
      :built ->
        {:ok, struct(event, attrs)}

      _ ->
        event
        |> Event.changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, %Event{} = updated} ->
            Cache.invalidate_event_cache(updated.id)
            Cache.invalidate_events_list_cache()
            {:ok, updated}

          other ->
            other
        end
    end
  end

  defp build_event_attrs(attrs, essentials) do
    event_datetime =
      Map.get(essentials, "event_date_time") ||
        Map.get(essentials, :event_date_time)

    {event_date, event_time} = split_datetime(event_datetime)
    {tickera_start_date, tickera_end_date} = resolve_tickera_window(attrs, essentials)

    %{
      name:
        fetch_attr(attrs, "name") || Map.get(essentials, "event_name") ||
          Map.get(essentials, :event_name),
      entrance_name: fetch_attr(attrs, "entrance_name"),
      location: fetch_attr(attrs, "location"),
      total_tickets: Map.get(essentials, "total_tickets") || Map.get(essentials, :total_tickets),
      event_date: fetch_attr(attrs, "event_date") || event_date,
      event_time: fetch_attr(attrs, "event_time") || event_time,
      tickera_start_date: tickera_start_date,
      tickera_end_date: tickera_end_date,
      last_sync_at: fetch_attr(attrs, "last_sync_at"),
      last_soft_sync_at: fetch_attr(attrs, "last_soft_sync_at")
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

  defp resolve_tickera_window(attrs, essentials) do
    start_source =
      fetch_attr(attrs, "tickera_start_date") ||
        Map.get(essentials, "event_start_date") ||
        Map.get(essentials, :event_start_date) ||
        Map.get(essentials, "event_date_time") ||
        Map.get(essentials, :event_date_time)

    end_source =
      fetch_attr(attrs, "tickera_end_date") ||
        Map.get(essentials, "event_end_date") ||
        Map.get(essentials, :event_end_date)

    {
      coerce_event_datetime(start_source),
      coerce_event_datetime(end_source)
    }
  end

  defp coerce_event_datetime(nil), do: nil

  defp coerce_event_datetime(%DateTime{} = datetime) do
    shift_to_utc(datetime)
  rescue
    _ -> nil
  end

  defp coerce_event_datetime(%NaiveDateTime{} = datetime) do
    case DateTime.from_naive(datetime, "Etc/UTC") do
      {:ok, utc} -> DateTime.truncate(utc, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(%Time{} = time) do
    DateTime.new(Date.utc_today(), time, "Etc/UTC")
    |> case do
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp coerce_event_datetime(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        with {:ok, datetime, _offset} <- DateTime.from_iso8601(trimmed) do
          shift_to_utc(datetime)
        else
          {:error, _} ->
            case NaiveDateTime.from_iso8601(trimmed) do
              {:ok, naive} -> coerce_event_datetime(naive)
              {:error, _} -> parse_unix_datetime(trimmed)
            end
        end
    end
  end

  defp coerce_event_datetime(value) when is_integer(value) do
    value
    |> DateTime.from_unix()
    |> case do
      {:ok, datetime} -> shift_to_utc(datetime)
      _ -> nil
    end
  end

  defp coerce_event_datetime(_value), do: nil

  defp parse_unix_datetime(trimmed) do
    case Integer.parse(trimmed) do
      {unix, ""} ->
        case DateTime.from_unix(unix) do
          {:ok, datetime} -> shift_to_utc(datetime)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp shift_to_utc(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone("Etc/UTC")
    |> case do
      {:ok, shifted} -> DateTime.truncate(shifted, :second)
      {:error, _} -> DateTime.truncate(datetime, :second)
    end
  end

  defp ensure_credentials(site_url, api_key) when is_binary(site_url) and is_binary(api_key) do
    with true <- present_binary?(site_url),
         true <- present_binary?(api_key) do
      case TickeraClient.check_credentials(site_url, api_key) do
        {:ok, response} when is_map(response) ->
          if credential_check_passed?(response) do
            :ok
          else
            {:error, :invalid_credentials}
          end

        {:ok, _response} ->
          {:error, :invalid_credentials}

        {:error, {:http_error, code, _body}}
        when code in [401, 403, 404] ->
          {:error, :invalid_credentials}

        {:error, {:http_error, _code, _body} = reason} ->
          {:error, {:credential_check_failed, reason}}

        {:error, {:network_timeout, _reason} = reason} ->
          {:error, {:credential_check_failed, reason}}

        {:error, {:network_error, _reason} = reason} ->
          {:error, {:credential_check_failed, reason}}

        {:error, {:exception, _message} = reason} ->
          {:error, {:credential_check_failed, reason}}

        {:error, reason} ->
          {:error, {:credential_check_failed, reason}}
      end
    else
      false -> {:error, :invalid_credentials}
    end
  end

  defp ensure_credentials(_site_url, _api_key), do: {:error, :invalid_credentials}

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp credential_check_passed?(%{"pass" => pass}) when pass in [true, "true", "1", 1], do: true
  defp credential_check_passed?(%{"pass" => _}), do: false
  defp credential_check_passed?(_response), do: false

  defp credential_error_message(:invalid_credentials),
    do: "Invalid API key or site URL mismatch"

  defp credential_error_message({:credential_check_failed, {:exception, message}})
       when is_binary(message) do
    "Tickera request configuration error: #{message}"
  end

  defp credential_error_message({:credential_check_failed, {:network_timeout, _reason}}) do
    "Tickera request timed out. Verify the site URL and network reachability."
  end

  defp credential_error_message({:credential_check_failed, {:network_error, _reason}}) do
    "Tickera network error. Verify the site URL (include https://) and connectivity."
  end

  defp credential_error_message({:credential_check_failed, {:http_error, code, _body}})
       when is_integer(code) do
    "Tickera rejected credential check with HTTP #{code}"
  end

  defp credential_error_message({:credential_check_failed, reason}) do
    "Tickera credential check failed: #{inspect(reason)}"
  end

  defp credential_error_message(reason) when is_binary(reason), do: reason
  defp credential_error_message(reason), do: inspect(reason)

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

  defp normalize_reference_datetime(nil), do: DateTime.utc_now() |> DateTime.to_naive()

  defp normalize_reference_datetime(%DateTime{} = datetime) do
    DateTime.to_naive(datetime)
  rescue
    _ -> normalize_reference_datetime(nil)
  end

  defp normalize_reference_datetime(%NaiveDateTime{} = datetime), do: datetime
  defp normalize_reference_datetime(_), do: normalize_reference_datetime(nil)

  defp normalize_event_datetime(nil), do: nil

  defp normalize_event_datetime(%NaiveDateTime{} = datetime), do: datetime

  defp normalize_event_datetime(%DateTime{} = datetime) do
    DateTime.to_naive(datetime)
  rescue
    _ -> nil
  end

  defp normalize_event_datetime(_), do: nil

  defp grace_period_end(nil), do: nil

  defp grace_period_end(%NaiveDateTime{} = end_time) do
    grace_days = event_post_grace_days()

    if grace_days > 0 do
      NaiveDateTime.add(end_time, grace_days * @seconds_per_day, :second)
    else
      end_time
    end
  end

  defp event_post_grace_days do
    val = Application.get_env(:fastcheck, :event_post_grace_days, 0)
    if is_integer(val) and val >= 0, do: val, else: 0
  end
end
