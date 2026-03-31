defmodule FastCheck.Devices.Device do
  @moduledoc """
  Registered native scanner handset.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Devices.DeviceSession

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: integer() | nil,
          installation_id: String.t() | nil,
          platform: String.t() | nil,
          label: String.t() | nil,
          app_version: String.t() | nil,
          status: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          sessions: [DeviceSession.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  schema "devices" do
    field :installation_id, :string
    field :platform, :string, default: "android"
    field :label, :string
    field :app_version, :string
    field :status, :string, default: "provisioned"
    field :last_seen_at, :utc_datetime

    has_many :sessions, DeviceSession

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:installation_id, :platform, :label, :app_version, :status, :last_seen_at])
    |> validate_required([:installation_id, :platform, :status])
    |> unique_constraint(:installation_id, name: :idx_devices_installation_id)
  end
end
