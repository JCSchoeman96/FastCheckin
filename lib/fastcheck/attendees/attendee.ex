defmodule FastCheck.Attendees.Attendee do
  @moduledoc """
  Defines the Attendee schema representing a single ticket holder synced from
  Tickera along with the metadata required to control entrance permissions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Events.Event

  @type t :: %__MODULE__{
          id: integer() | nil,
          event_id: integer() | nil,
          ticket_code: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          email: String.t() | nil,
          ticket_type_id: pos_integer() | nil,
          ticket_type: String.t() | nil,
          allowed_checkins: integer() | nil,
          checkins_remaining: integer() | nil,
          payment_status: String.t() | nil,
          custom_fields: map() | nil,
          checked_in_at: DateTime.t() | nil,
          checked_out_at: DateTime.t() | nil,
          last_checked_in_at: DateTime.t() | nil,
          last_checked_in_date: Date.t() | nil,
          daily_scan_count: integer() | nil,
          weekly_scan_count: integer() | nil,
          monthly_scan_count: integer() | nil,
          is_currently_inside: boolean() | nil,
          last_entrance: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          event: Event.t() | Ecto.Association.NotLoaded.t()
        }

  schema "attendees" do
    # Foreign key referencing the event this attendee belongs to
    belongs_to :event, Event
    # Unique ticket identifier issued by Tickera
    field :ticket_code, :string
    # Attendee's given name for personalized messaging and search
    field :first_name, :string
    # Attendee's surname for identification and reporting
    field :last_name, :string
    # Contact email used for confirmations or receipts
    field :email, :string
    # Numeric Tickera ticket type identifier for config lookups
    field :ticket_type_id, :integer
    # Ticket category (General Admission, VIP, etc.) for filtering and rules
    field :ticket_type, :string
    # Total number of times the attendee is allowed to check in
    field :allowed_checkins, :integer
    # Remaining check-ins before the ticket is exhausted
    field :checkins_remaining, :integer
    # Payment status pulled from Tickera (paid, pending, refunded)
    field :payment_status, :string
    # Arbitrary metadata blob from Tickera custom fields
    field :custom_fields, :map
    # Timestamp of the first time the ticket was scanned
    field :checked_in_at, :utc_datetime
    # Timestamp of the most recent time the attendee exited the venue
    field :checked_out_at, :utc_datetime
    # Timestamp of the most recent check-in attempt
    field :last_checked_in_at, :utc_datetime
    # Date of the most recent check-in for rate limiting logic
    field :last_checked_in_date, :date
    # Running counters for rate limiting windows
    field :daily_scan_count, :integer, default: 0
    field :weekly_scan_count, :integer, default: 0
    field :monthly_scan_count, :integer, default: 0
    # Tracks if the attendee is currently inside the venue
    field :is_currently_inside, :boolean, default: false
    # Stores the last entrance used during check-in
    field :last_entrance, :string

    # inserted_at/updated_at timestamps for auditing changes
    timestamps()
  end

  @doc """
  Builds an attendee changeset for create/update operations, enforcing required
  fields and ticket uniqueness per event.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attendee, attrs) do
    attendee
    |> cast(attrs, [
      :ticket_code,
      :first_name,
      :last_name,
      :email,
      :ticket_type_id,
      :ticket_type,
      :allowed_checkins,
      :checkins_remaining,
      :payment_status,
      :custom_fields,
      :checked_in_at,
      :checked_out_at,
      :last_checked_in_at,
      :last_checked_in_date,
      :daily_scan_count,
      :weekly_scan_count,
      :monthly_scan_count,
      :is_currently_inside,
      :last_entrance,
      :event_id
    ])
    |> validate_required([:ticket_code, :event_id])
    |> unique_constraint(:ticket_code, name: :unique_ticket_per_event)
  end
end
