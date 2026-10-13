defmodule FastCheck.Events.SyncLog do
  @moduledoc """
  Schema for sync operation audit logs.

  Tracks every sync attempt with timing, status, and results for auditing and debugging.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Repo

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          event: FastCheck.Events.Event.t() | Ecto.Association.NotLoaded.t(),
          id: integer() | nil,
          event_id: integer() | nil,
          sync_run_id: binary() | nil,
          owner_token: binary() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          heartbeat_at: DateTime.t() | nil,
          status: String.t() | nil,
          attendees_synced: integer() | nil,
          total_pages: integer() | nil,
          pages_processed: integer() | nil,
          error_message: String.t() | nil,
          duration_ms: integer() | nil,
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "sync_logs" do
    belongs_to :event, FastCheck.Events.Event

    field :sync_run_id, Ecto.UUID
    field :owner_token, Ecto.UUID
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :lease_expires_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
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
  Lists recent sync logs for an event, ordered by most recent first.
  """
  @spec list_event_sync_logs(integer(), integer()) :: [t()]
  def list_event_sync_logs(event_id, limit \\ 10) when is_integer(event_id) do
    import Ecto.Query

    __MODULE__
    |> where([s], s.event_id == ^event_id)
    |> order_by([s], desc: s.started_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
