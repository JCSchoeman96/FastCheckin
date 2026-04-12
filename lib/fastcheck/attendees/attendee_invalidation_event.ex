defmodule FastCheck.Attendees.AttendeeInvalidationEvent do
  @moduledoc """
  Append-only invalidation events for scanner sync (tombstones for not_scannable transitions).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event

  schema "attendee_invalidation_events" do
    belongs_to :event, Event
    belongs_to :attendee, Attendee
    field :ticket_code, :string
    field :change_type, :string
    field :reason_code, :string
    field :effective_at, :utc_datetime
    field :source_sync_run_id, Ecto.UUID

    timestamps(updated_at: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = struct, attrs) do
    struct
    |> cast(attrs, [
      :event_id,
      :attendee_id,
      :ticket_code,
      :change_type,
      :reason_code,
      :effective_at,
      :source_sync_run_id
    ])
    |> validate_required([
      :event_id,
      :attendee_id,
      :ticket_code,
      :change_type,
      :reason_code,
      :effective_at
    ])
  end
end
