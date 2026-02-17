defmodule FastCheck.Events.SyncState do
  @moduledoc """
  Manages sync state for pause/resume functionality.

  Uses an Agent to track sync state per event, allowing pause/resume operations.
  """

  use Agent

  @type sync_state :: :running | :paused | :cancelled
  @type state_map :: %{
    status: sync_state(),
    current_page: integer(),
    total_pages: integer(),
    attendees_processed: integer(),
    sync_log_id: integer() | nil
  }

  @doc """
  Starts the sync state agent.
  """
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Initializes sync state for an event.
  """
  @spec init_sync(integer(), integer() | nil) :: :ok
  def init_sync(event_id, sync_log_id \\ nil) when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      Map.put(state, event_id, %{
        status: :running,
        current_page: 0,
        total_pages: nil,
        attendees_processed: 0,
        sync_log_id: sync_log_id
      })
    end)
  end

  @doc """
  Updates sync progress.
  """
  @spec update_progress(integer(), integer(), integer(), integer()) :: :ok
  def update_progress(event_id, page, total_pages, attendees_count)
      when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, event_id) do
        nil ->
          state

        current_state ->
          updated =
            current_state
            |> Map.put(:current_page, page)
            |> Map.put(:total_pages, total_pages)
            |> Map.put(:attendees_processed, attendees_count)

          Map.put(state, event_id, updated)
      end
    end)
  end

  @doc """
  Pauses sync for an event.
  """
  @spec pause_sync(integer()) :: :ok | {:error, :not_found}
  def pause_sync(event_id) when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, event_id) do
        nil ->
          state

        current_state ->
          updated = Map.put(current_state, :status, :paused)
          Map.put(state, event_id, updated)
      end
    end)

    case Agent.get(__MODULE__, &Map.get(&1, event_id)) do
      nil -> {:error, :not_found}
      _ -> :ok
    end
  end

  @doc """
  Resumes sync for an event.
  """
  @spec resume_sync(integer()) :: :ok | {:error, :not_found}
  def resume_sync(event_id) when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, event_id) do
        nil ->
          state

        current_state ->
          updated = Map.put(current_state, :status, :running)
          Map.put(state, event_id, updated)
      end
    end)

    case Agent.get(__MODULE__, &Map.get(&1, event_id)) do
      nil -> {:error, :not_found}
      _ -> :ok
    end
  end

  @doc """
  Cancels sync for an event.
  """
  @spec cancel_sync(integer()) :: :ok
  def cancel_sync(event_id) when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, event_id) do
        nil ->
          state

        current_state ->
          updated = Map.put(current_state, :status, :cancelled)
          Map.put(state, event_id, updated)
      end
    end)
  end

  @doc """
  Gets sync state for an event.
  """
  @spec get_state(integer()) :: state_map() | nil
  def get_state(event_id) when is_integer(event_id) do
    Agent.get(__MODULE__, &Map.get(&1, event_id))
  end

  @doc """
  Checks if sync should continue (not paused or cancelled).
  """
  @spec should_continue?(integer()) :: boolean()
  def should_continue?(event_id) when is_integer(event_id) do
    case get_state(event_id) do
      %{status: :running} -> true
      _ -> false
    end
  end

  @doc """
  Clears sync state for an event (after completion or cancellation).
  """
  @spec clear_state(integer()) :: :ok
  def clear_state(event_id) when is_integer(event_id) do
    Agent.update(__MODULE__, fn state ->
      Map.delete(state, event_id)
    end)
  end

  @doc """
  Gets the last processed page for resuming.
  """
  @spec get_resume_page(integer()) :: integer()
  def get_resume_page(event_id) when is_integer(event_id) do
    case get_state(event_id) do
      %{current_page: page} when is_integer(page) -> max(0, page)
      _ -> 0
    end
  end
end
