defmodule FastCheck.Attendees.CheckInSession do
  @moduledoc """
  Tracks a single attendee's presence in the venue by recording entry and exit
  timestamps for each visit.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          attendee_id: integer(),
          event_id: integer(),
          entry_time: DateTime.t(),
          exit_time: DateTime.t() | nil,
          entrance_name: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "check_in_sessions" do
    belongs_to :attendee, Attendee
    belongs_to :event, Event

    field :entry_time, :utc_datetime
    field :exit_time, :utc_datetime
    field :entrance_name, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for creating or updating attendee session records.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:attendee_id, :event_id, :entry_time, :exit_time, :entrance_name])
    |> validate_required([:attendee_id, :event_id, :entry_time, :entrance_name])
    |> validate_length(:entrance_name, min: 1, max: 100)
  end
end
