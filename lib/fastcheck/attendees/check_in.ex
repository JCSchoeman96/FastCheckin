defmodule FastCheck.Attendees.CheckIn do
  @moduledoc """
  Schema for attendee check-ins that acts as an audit trail of who was admitted,
  when they were processed, and through which entrance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Each check-in record is a snapshot we can review later when auditing event operations.
  schema "check_ins" do
    belongs_to :attendee, FastCheck.Attendees.Attendee
    belongs_to :event, FastCheck.Events.Event

    field :ticket_code, :string
    field :checked_in_at, :utc_datetime
    field :entrance_name, :string
    field :operator_name, :string
    field :status, :string
    field :notes, :string

    timestamps(updated_at: false)
  end

  @doc """
  Builds a changeset for creating or updating a check-in entry in the audit trail.
  """
  def changeset(check_in, attrs) do
    check_in
    |> cast(attrs, [
      :attendee_id,
      :event_id,
      :ticket_code,
      :entrance_name,
      :operator_name,
      :status,
      :notes,
      :checked_in_at
    ])
    |> validate_required([:event_id, :ticket_code, :checked_in_at])
  end
end
