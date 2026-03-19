defmodule FastCheck.Scans.ScanAttempt do
  @moduledoc """
  Durable append-only audit record for mobile scan ingestion outcomes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event

  @type t :: %__MODULE__{}

  schema "scan_attempts" do
    belongs_to :event, Event
    belongs_to :attendee, Attendee

    field :idempotency_key, :string
    field :ticket_code, :string
    field :direction, :string
    field :status, :string
    field :reason_code, :string
    field :message, :string
    field :entrance_name, :string
    field :operator_name, :string
    field :scanned_at, :utc_datetime
    field :processed_at, :utc_datetime
    field :hot_state_version, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(scan_attempt, attrs) do
    scan_attempt
    |> cast(attrs, [
      :event_id,
      :attendee_id,
      :idempotency_key,
      :ticket_code,
      :direction,
      :status,
      :reason_code,
      :message,
      :entrance_name,
      :operator_name,
      :scanned_at,
      :processed_at,
      :hot_state_version,
      :metadata
    ])
    |> validate_required([
      :event_id,
      :idempotency_key,
      :ticket_code,
      :direction,
      :status,
      :processed_at
    ])
    |> unique_constraint([:event_id, :idempotency_key],
      name: :scan_attempts_event_idempotency_key_idx
    )
  end
end
