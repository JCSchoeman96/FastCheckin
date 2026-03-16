defmodule FastCheck.CheckIns.OfflineEventPackage do
  @moduledoc """
  Versioned metadata for event-scoped offline packages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Ticketing.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          version: integer() | nil,
          status: String.t() | nil,
          checksum: String.t() | nil,
          generated_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: map() | nil
        }

  schema "offline_event_packages" do
    belongs_to :event, Event
    field :version, :integer
    field :status, :string
    field :checksum, :string
    field :generated_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :metadata, :map

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(package, attrs) do
    package
    |> cast(attrs, [
      :event_id,
      :version,
      :status,
      :checksum,
      :generated_at,
      :expires_at,
      :metadata
    ])
    |> validate_required([:event_id, :version, :status])
    |> unique_constraint(:version, name: :idx_offline_event_packages_event_version)
  end
end
