defmodule FastCheck.Ticketing.SyncCursor do
  @moduledoc """
  Tracks upstream sync watermarks for Tickera imports.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Ticketing.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          source: String.t() | nil,
          cursor: String.t() | nil,
          last_synced_at: DateTime.t() | nil
        }

  schema "sync_cursors" do
    belongs_to :event, Event
    field :source, :string, default: "tickera"
    field :cursor, :string
    field :last_synced_at, :utc_datetime

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:event_id, :source, :cursor, :last_synced_at])
    |> validate_required([:event_id, :source])
    |> unique_constraint(:source, name: :idx_sync_cursors_event_source)
  end
end
