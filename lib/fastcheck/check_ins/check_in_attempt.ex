defmodule FastCheck.CheckIns.CheckInAttempt do
  @moduledoc """
  Immutable audit record for native scanner scan attempts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Devices.{Device, DeviceSession}
  alias FastCheck.Ticketing.{Event, Gate, Ticket}

  @type t :: %__MODULE__{
          id: integer() | nil,
          attendee_id: integer() | nil,
          event_id: integer() | nil,
          gate_id: integer() | nil,
          device_id: integer() | nil,
          device_session_id: integer() | nil,
          request_id: String.t() | nil,
          ticket_code: String.t() | nil,
          checked_in_at: DateTime.t() | nil,
          scanned_at_device: DateTime.t() | nil,
          decision: String.t() | nil,
          reconciliation_state: String.t() | nil,
          connectivity_mode: String.t() | nil,
          app_version: String.t() | nil
        }

  schema "check_ins" do
    belongs_to :ticket, Ticket, foreign_key: :attendee_id
    belongs_to :event, Event
    belongs_to :gate, Gate
    belongs_to :device, Device
    belongs_to :device_session, DeviceSession

    field :request_id, :string
    field :ticket_code, :string
    field :checked_in_at, :utc_datetime
    field :scanned_at_device, :utc_datetime
    field :entrance_name, :string
    field :operator_name, :string
    field :status, :string
    field :notes, :string
    field :decision, :string
    field :reconciliation_state, :string
    field :connectivity_mode, :string
    field :app_version, :string
    field :feedback_tone, :string
    field :feedback_color, :string
    field :display_name, :string
    field :ticket_label, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(check_in, attrs) do
    check_in
    |> cast(attrs, [
      :attendee_id,
      :event_id,
      :gate_id,
      :device_id,
      :device_session_id,
      :request_id,
      :ticket_code,
      :checked_in_at,
      :scanned_at_device,
      :entrance_name,
      :operator_name,
      :status,
      :notes,
      :decision,
      :reconciliation_state,
      :connectivity_mode,
      :app_version,
      :feedback_tone,
      :feedback_color,
      :display_name,
      :ticket_label
    ])
    |> validate_required([:event_id, :ticket_code, :checked_in_at, :status, :decision])
  end
end
