defmodule FastCheck.Events.SyncLog do
  @moduledoc """
  Schema for sync operation audit logs.

  Tracks every sync attempt with timing, status, and results for auditing and debugging.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer(),
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil,
          status: String.t(),
          attendees_synced: integer(),
          total_pages: integer() | nil,
          pages_processed: integer(),
          error_message: String.t() | nil,
          duration_ms: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sync_logs" do
    belongs_to :event, FastCheck.Events.Event

    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :status, :string
    field :attendees_synced, :integer, default: 0
    field :total_pages, :integer
    field :pages_processed, :integer, default: 0
    field :error_message, :string
    field :duration_ms, :integer

    timestamps()
  end

  @doc """
  Builds a changeset for creating a sync log entry.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [
      :event_id,
      :started_at,
      :completed_at,
      :status,
      :attendees_synced,
      :total_pages,
      :pages_processed,
      :error_message,
      :duration_ms
    ])
    |> validate_required([:event_id, :started_at, :status])
    |> validate_inclusion(:status, ["in_progress", "completed", "failed", "paused", "cancelled"])
  end

  @doc """
  Creates a new sync log entry for a started sync.
  """
  @spec log_sync_start(integer()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_sync_start(event_id) when is_integer(event_id) do
    %__MODULE__{}
    |> changeset(%{
      event_id: event_id,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "in_progress",
      pages_processed: 0,
      attendees_synced: 0
    })
    |> FastCheck.Repo.insert()
  end

  @doc """
  Updates a sync log entry with completion status.
  """
  @spec log_sync_completion(integer(), String.t(), integer(), integer()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_sync_completion(sync_log_id, status, attendees_synced, pages_processed)
      when is_integer(sync_log_id) do
    sync_log = FastCheck.Repo.get!(__MODULE__, sync_log_id)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    duration_ms =
      if sync_log.started_at do
        DateTime.diff(completed_at, sync_log.started_at, :millisecond)
      else
        nil
      end

    sync_log
    |> changeset(%{
      completed_at: completed_at,
      status: status,
      attendees_synced: attendees_synced,
      pages_processed: pages_processed,
      duration_ms: duration_ms
    })
    |> FastCheck.Repo.update()
  end

  @doc """
  Updates a sync log entry with error information.
  """
  @spec log_sync_error(integer(), String.t(), integer()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def log_sync_error(sync_log_id, error_message, pages_processed)
      when is_integer(sync_log_id) do
    sync_log = FastCheck.Repo.get!(__MODULE__, sync_log_id)
    completed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    duration_ms =
      if sync_log.started_at do
        DateTime.diff(completed_at, sync_log.started_at, :millisecond)
      else
        nil
      end

    sync_log
    |> changeset(%{
      completed_at: completed_at,
      status: "failed",
      error_message: error_message,
      pages_processed: pages_processed,
      duration_ms: duration_ms
    })
    |> FastCheck.Repo.update()
  end

  @doc """
  Updates sync progress (pages processed).
  """
  @spec update_progress(integer(), integer(), integer()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def update_progress(sync_log_id, pages_processed, attendees_synced)
      when is_integer(sync_log_id) do
    sync_log = FastCheck.Repo.get!(__MODULE__, sync_log_id)

    sync_log
    |> changeset(%{
      pages_processed: pages_processed,
      attendees_synced: attendees_synced
    })
    |> FastCheck.Repo.update()
  end

  @doc """
  Lists recent sync logs for an event, ordered by most recent first.
  """
  @spec list_event_sync_logs(integer(), integer()) :: [t()]
  def list_event_sync_logs(event_id, limit \\ 10) when is_integer(event_id) do
    import Ecto.Query

    __MODULE__
    |> where([s], s.event_id == ^event_id)
    |> order_by([s], desc: s.started_at)
    |> limit(^limit)
    |> FastCheck.Repo.all()
  end
end
