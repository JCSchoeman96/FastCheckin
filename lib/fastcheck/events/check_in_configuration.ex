defmodule FastCheck.Events.CheckInConfiguration do
  @moduledoc """
  Stores Tickera ticket-type configuration data for enforcing local check-in rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Events.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          ticket_type_id: integer() | nil,
          ticket_type: String.t() | nil,
          ticket_name: String.t() | nil,
          allowed_checkins: integer() | nil,
          allow_reentry: boolean() | nil,
          allowed_entrances: map() | nil,
          check_in_window_start: Date.t() | nil,
          check_in_window_end: Date.t() | nil,
          check_in_window_timezone: String.t() | nil,
          check_in_window_days: integer() | nil,
          check_in_window_buffer_minutes: integer() | nil,
          time_basis: String.t() | nil,
          time_basis_timezone: String.t() | nil,
          daily_check_in_limit: integer() | nil,
          entrance_limit: integer() | nil,
          limit_per_order: integer() | nil,
          min_per_order: integer() | nil,
          max_per_order: integer() | nil,
          status: String.t() | nil,
          message: String.t() | nil,
          last_checked_in_date: Date.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "check_in_configurations" do
    belongs_to :event, Event
    field :ticket_type_id, :integer
    field :ticket_type, :string
    field :ticket_name, :string
    field :allowed_checkins, :integer
    field :allow_reentry, :boolean
    field :allowed_entrances, :map
    field :check_in_window_start, :date
    field :check_in_window_end, :date
    field :check_in_window_timezone, :string
    field :check_in_window_days, :integer
    field :check_in_window_buffer_minutes, :integer
    field :time_basis, :string
    field :time_basis_timezone, :string
    field :daily_check_in_limit, :integer
    field :entrance_limit, :integer
    field :limit_per_order, :integer
    field :min_per_order, :integer
    field :max_per_order, :integer
    field :status, :string
    field :message, :string
    field :last_checked_in_date, :date

    timestamps()
  end

  @fields [
    :event_id,
    :ticket_type_id,
    :ticket_type,
    :ticket_name,
    :allowed_checkins,
    :allow_reentry,
    :allowed_entrances,
    :check_in_window_start,
    :check_in_window_end,
    :check_in_window_timezone,
    :check_in_window_days,
    :check_in_window_buffer_minutes,
    :time_basis,
    :time_basis_timezone,
    :daily_check_in_limit,
    :entrance_limit,
    :limit_per_order,
    :min_per_order,
    :max_per_order,
    :status,
    :message,
    :last_checked_in_date
  ]

  @doc """
  Validates configuration payloads before persistence.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, @fields)
    |> validate_required([:event_id, :ticket_type_id])
    |> unique_constraint(:ticket_type_id, name: :idx_configs_event_ticket_type)
    |> foreign_key_constraint(:event_id)
  end
end
