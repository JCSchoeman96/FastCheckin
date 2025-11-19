defmodule FastCheck.Cache.EtsLayer do
  @moduledoc """
  ETS-based L1 cache for FastCheck.

  - Shared across all processes on a node.
  - Ultra-fast lookups for hot data (attendees, events, entrances).
  - No business logic, just storage + retrieval.
  """

  require Logger

  @attendee_table :fastcheck_attendees
  @event_table :fastcheck_events
  @entrance_table :fastcheck_entrances

  # ========= PUBLIC API =========

  @doc """
  Create ETS tables if they don't exist yet.

  To be called once at application start from a supervised Task.
  """
  def init do
    Logger.info("Initializing FastCheck ETS L1 cache tables")

    create_table(@attendee_table, read_concurrency: true, write_concurrency: true)
    create_table(@event_table, read_concurrency: true)
    create_table(@entrance_table, read_concurrency: true, write_concurrency: true)

    :ok
  end

  # ----- Attendees -----

  @doc """
  Cache a single attendee for an event by ticket_code.

  Key: {event_id, ticket_code}
  """
  def put_attendee(event_id, ticket_code, attendee_struct) do
    key = {event_id, ticket_code}
    :ets.insert(@attendee_table, {key, attendee_struct})
    :ok
  end

  @doc """
  Bulk cache attendees for an event.

  Accepts a list of %{ticket_code: code} structs or maps.
  """
  def put_attendees(event_id, attendees) when is_list(attendees) do
    entries =
      Enum.map(attendees, fn attendee ->
        key = {event_id, attendee.ticket_code}
        {key, attendee}
      end)

    :ets.insert(@attendee_table, entries)
    :ok
  end

  @doc """
  Fetch an attendee by event_id + ticket_code.

  Returns {:ok, attendee} | :not_found.
  """
  def get_attendee(event_id, ticket_code) do
    key = {event_id, ticket_code}

    case :ets.lookup(@attendee_table, key) do
      [{^key, attendee}] -> {:ok, attendee}
      [] -> :not_found
    end
  end

  @doc """
  Remove all cached attendees for a given event.
  """
  def invalidate_attendees(event_id) do
    match_spec = [{{{event_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@attendee_table, match_spec)
    :ok
  end

  # ----- Events -----

  @doc """
  Cache event configuration by event_id.

  Key: event_id
  """
  def put_event_config(event_id, event_struct) do
    :ets.insert(@event_table, {event_id, event_struct})
    :ok
  end

  @doc """
  Fetch event configuration from ETS.

  Returns {:ok, event} | :not_found.
  """
  def get_event_config(event_id) do
    case :ets.lookup(@event_table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> :not_found
    end
  end

  @doc """
  Invalidate a single event config entry.
  """
  def invalidate_event_config(event_id) do
    :ets.delete(@event_table, event_id)
    :ok
  end

  # ----- Entrances -----

  @doc """
  Cache a single entrance under {event_id, entrance_id}.
  """
  def put_entrance(event_id, entrance_id, entrance_struct) do
    key = {event_id, entrance_id}
    :ets.insert(@entrance_table, {key, entrance_struct})
    :ok
  end

  @doc """
  Bulk cache entrances for an event.
  """
  def put_entrances(event_id, entrances) do
    entries =
      Enum.map(entrances, fn entrance ->
        key = {event_id, entrance.id}
        {key, entrance}
      end)

    :ets.insert(@entrance_table, entries)
    :ok
  end

  @doc """
  Get a single entrance.

  Returns {:ok, entrance} | :not_found.
  """
  def get_entrance(event_id, entrance_id) do
    key = {event_id, entrance_id}

    case :ets.lookup(@entrance_table, key) do
      [{^key, entrance}] -> {:ok, entrance}
      [] -> :not_found
    end
  end

  @doc """
  Get all entrances for an event as a list.
  """
  def list_entrances(event_id) do
    match_spec = [{{{event_id, :_}, :_}, [], [:"$_"]}]

    @entrance_table
    |> :ets.select(match_spec)
    |> Enum.map(fn {{^event_id, _entrance_id}, entrance} -> entrance end)
  end

  @doc """
  Invalidate all entrances for an event.
  """
  def invalidate_entrances(event_id) do
    match_spec = [{{{event_id, :_}, :_}, [], [true]}]
    :ets.select_delete(@entrance_table, match_spec)
    :ok
  end

  # ----- Maintenance / Debug -----

  @doc """
  Clear all ETS cache tables (for tests and maintenance).
  """
  def flush_all do
    :ets.delete_all_objects(@attendee_table)
    :ets.delete_all_objects(@event_table)
    :ets.delete_all_objects(@entrance_table)
    :ok
  end

  @doc """
  Return basic stats for monitoring.
  """
  def stats do
    %{
      attendees: table_size(@attendee_table),
      events: table_size(@event_table),
      entrances: table_size(@entrance_table)
    }
  end

  # ========= INTERNALS =========

  defp create_table(name, opts) do
    # Only create if not already created – safe for code reloads.
    case :ets.info(name) do
      :undefined ->
        base_opts = [:set, :public, {:read_concurrency, true}]
        :ets.new(name, Keyword.merge(base_opts, opts))

      _info ->
        name
    end
  end

  defp table_size(name) do
    case :ets.info(name, :size) do
      :undefined -> 0
      size -> size
    end
  end
end
