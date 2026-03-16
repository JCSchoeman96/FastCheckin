defmodule FastCheck.Ticketing.Ticket do
  @moduledoc """
  Native scanner view of a ticket mapped onto the existing attendees table.
  """

  use Ecto.Schema

  alias FastCheck.Ticketing.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          ticket_code: String.t() | nil,
          normalized_code: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          payment_status: String.t() | nil,
          ticket_type: String.t() | nil,
          allowed_checkins: integer() | nil,
          checkins_remaining: integer() | nil,
          event: Event.t() | Ecto.Association.NotLoaded.t()
        }

  schema "attendees" do
    belongs_to :event, Event
    field :ticket_code, :string
    field :normalized_code, :string
    field :first_name, :string
    field :last_name, :string
    field :payment_status, :string
    field :ticket_type, :string
    field :allowed_checkins, :integer
    field :checkins_remaining, :integer

    timestamps()
  end
end
