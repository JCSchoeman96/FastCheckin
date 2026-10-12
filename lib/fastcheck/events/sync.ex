defmodule FastCheck.Events.Sync do
  @moduledoc """
  Shared credential and attendee helpers used by guarded SyncRun execution.
  """

  import Ecto.Query, warn: false
  require Logger

  alias FastCheck.Attendees
  alias FastCheck.Crypto
  alias FastCheck.Events.Cache
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.TickeraClient

  @doc "Decrypts the stored Tickera API key for the event."
  @spec get_tickera_api_key(Event.t() | nil) :: {:ok, String.t()} | {:error, :decryption_failed}
  def get_tickera_api_key(%Event{id: id, tickera_api_key_encrypted: encrypted})
      when is_binary(encrypted) do
    case Crypto.decrypt(encrypted) do
      {:ok, api_key} when is_binary(api_key) ->
        case String.trim(api_key) do
          "" ->
            Logger.warning("Tickera API key is empty after normalization for event #{id}")
            {:error, :decryption_failed}

          normalized ->
            {:ok, normalized}
        end

      {:error, _reason} ->
        Logger.warning("Unable to decrypt Tickera API key for event #{id}")
        {:error, :decryption_failed}
    end
  end

  def get_tickera_api_key(%Event{id: id}) do
    Logger.warning("Event #{id} is missing encrypted Tickera credentials")
    {:error, :decryption_failed}
  end

  def get_tickera_api_key(_), do: {:error, :decryption_failed}

  @doc "Updates `last_sync_at` to the current timestamp for the event."
  @spec touch_last_sync(integer()) :: :ok | {:error, term()}
  def touch_last_sync(event_id) when is_integer(event_id) and event_id > 0 do
    timestamp = current_timestamp()
    update_sync_timestamp(event_id, %{last_sync_at: timestamp})
  end

  def touch_last_sync(_), do: {:error, :invalid_event}

  @doc "Updates `last_soft_sync_at` to the current timestamp for the event."
  @spec touch_last_soft_sync(integer()) :: :ok | {:error, term()}
  def touch_last_soft_sync(event_id) when is_integer(event_id) and event_id > 0 do
    timestamp = current_timestamp()
    update_sync_timestamp(event_id, %{last_soft_sync_at: timestamp})
  end

  def touch_last_soft_sync(_), do: {:error, :invalid_event}

  @doc "Selects new and changed attendees for an incremental SyncRun."
  @spec incremental_attendees_for_sync(integer(), list(map()), DateTime.t() | nil) :: list(map())
  def incremental_attendees_for_sync(event_id, attendees, last_sync_at) do
    if is_nil(last_sync_at) do
      Logger.info("No previous sync found, processing all #{length(attendees)} attendees")
      attendees
    else
      existing_attendees_by_code = get_existing_incremental_sync_fields(event_id)

      new_attendees =
        Enum.filter(attendees, fn attendee ->
          case attendee_ticket_code(attendee) do
            nil ->
              false

            ticket_code ->
              incremental_attendee_changed?(
                attendee,
                ticket_code,
                existing_attendees_by_code
              )
          end
        end)

      Logger.info(
        "Incremental sync: #{length(new_attendees)} new/updated attendees out of #{length(attendees)} total"
      )

      new_attendees
    end
  end

  defp attendee_ticket_code(attendee) do
    Map.get(attendee, :ticket_code) ||
      Map.get(attendee, "ticket_code") ||
      Map.get(attendee, "checksum")
  end

  defp attendee_incremental_sync_fields(attendee) do
    parsed = TickeraClient.parse_attendee(attendee)

    %{
      first_name: Map.get(parsed, :first_name),
      last_name: Map.get(parsed, :last_name),
      email: Map.get(parsed, :email),
      payment_status: Map.get(parsed, :payment_status),
      ticket_type: Map.get(parsed, :ticket_type),
      allowed_checkins: Attendees.normalize_allowed_checkins(Map.get(parsed, :allowed_checkins))
    }
  end

  defp incremental_attendee_changed?(attendee, ticket_code, existing_attendees_by_code) do
    remote_fields = attendee_incremental_sync_fields(attendee)

    case Map.get(existing_attendees_by_code, ticket_code) do
      nil -> true
      existing_fields -> existing_fields != remote_fields
    end
  end

  defp get_existing_incremental_sync_fields(event_id) do
    import Ecto.Query

    FastCheck.Attendees.Attendee
    |> where([a], a.event_id == ^event_id)
    |> select([a], %{
      ticket_code: a.ticket_code,
      first_name: a.first_name,
      last_name: a.last_name,
      email: a.email,
      payment_status: a.payment_status,
      ticket_type: a.ticket_type,
      allowed_checkins: a.allowed_checkins
    })
    |> Repo.all(timeout: 15_000)
    |> Map.new(fn attendee ->
      {attendee.ticket_code,
       %{
         first_name: attendee.first_name,
         last_name: attendee.last_name,
         email: attendee.email,
         payment_status: attendee.payment_status,
         ticket_type: attendee.ticket_type,
         allowed_checkins: Attendees.normalize_allowed_checkins(attendee.allowed_checkins)
       }}
    end)
  rescue
    exception ->
      if query_timeout_exception?(exception) do
        Logger.warning(
          "Query timeout fetching existing attendees for event #{event_id}; " <>
            "falling back to include all remote attendees in incremental sync"
        )
      else
        Logger.warning(
          "Database error fetching existing attendees for event #{event_id}; " <>
            "falling back to include all remote attendees in incremental sync: " <>
            Exception.message(exception)
        )
      end

      %{}
  end

  defp update_sync_timestamp(event_id, updates) do
    from(event in Event, where: event.id == ^event_id)
    |> Repo.update_all(set: Map.to_list(updates))
    |> case do
      {1, _} ->
        Cache.invalidate_event_cache(event_id)
        Cache.invalidate_events_list_cache()
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  defp current_timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp query_timeout_exception?(%{__struct__: struct}) when is_atom(struct),
    do: Atom.to_string(struct) == "Elixir.DBConnection.QueryError"
end
