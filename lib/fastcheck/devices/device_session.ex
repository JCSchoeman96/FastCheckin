defmodule FastCheck.Devices.DeviceSession do
  @moduledoc """
  Event-scoped native device session.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Devices.Device
  alias FastCheck.Ticketing.{Event, Gate}

  @type t :: %__MODULE__{
          id: integer() | nil,
          device_id: integer() | nil,
          event_id: integer() | nil,
          gate_id: integer() | nil,
          operator_name: String.t() | nil,
          app_version: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          device: Device.t() | Ecto.Association.NotLoaded.t(),
          event: Event.t() | Ecto.Association.NotLoaded.t(),
          gate: Gate.t() | Ecto.Association.NotLoaded.t()
        }

  schema "device_sessions" do
    belongs_to :device, Device
    belongs_to :event, Event
    belongs_to :gate, Gate
    field :operator_name, :string
    field :app_version, :string
    field :last_seen_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :device_id,
      :event_id,
      :gate_id,
      :operator_name,
      :app_version,
      :last_seen_at,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:device_id, :event_id, :expires_at])
  end
end
