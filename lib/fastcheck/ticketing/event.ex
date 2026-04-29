defmodule FastCheck.Ticketing.Event do
  @moduledoc """
  Native scanner view of an event.
  """

  use Ecto.Schema

  alias FastCheck.Ticketing.Gate

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          shortname: String.t() | nil,
          scanner_login_code: String.t() | nil,
          status: String.t() | nil,
          entrance_name: String.t() | nil,
          location: String.t() | nil,
          total_tickets: integer() | nil,
          checked_in_count: integer(),
          mobile_access_secret_encrypted: String.t() | nil,
          scanner_policy_mode: String.t() | nil,
          config_version: integer() | nil,
          gates: [Gate.t()] | Ecto.Association.NotLoaded.t()
        }

  schema "events" do
    field :name, :string
    field :shortname, :string
    field :scanner_login_code, :string
    field :status, :string
    field :entrance_name, :string
    field :location, :string
    field :total_tickets, :integer
    field :checked_in_count, :integer, virtual: true, default: 0
    field :mobile_access_secret_encrypted, :string
    field :scanner_policy_mode, :string
    field :config_version, :integer

    has_many :gates, Gate

    timestamps()
  end
end
