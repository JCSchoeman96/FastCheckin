defmodule FastCheck.Ticketing.Gate do
  @moduledoc """
  Entry lane metadata for the native scanner API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Ticketing.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          status: String.t() | nil
        }

  schema "gates" do
    belongs_to :event, Event
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(gate, attrs) do
    gate
    |> cast(attrs, [:event_id, :name, :slug, :status])
    |> validate_required([:event_id, :name, :slug])
    |> unique_constraint(:slug, name: :idx_gates_event_slug)
  end
end
