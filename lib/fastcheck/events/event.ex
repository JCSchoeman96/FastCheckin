defmodule FastCheck.Events.Event do
  @moduledoc """
  Defines the Event schema which stores metadata about every synced Tickera event
  including its status, entrance configuration, and sync timestamps. Tickera start
  and end timestamps are stored as UTC datetimes so lifecycle helpers can reliably
  determine when scanning should open, close, and move into the grace period.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          tickera_api_key_encrypted: String.t() | nil,
          tickera_api_key_last4: String.t() | nil,
          tickera_site_url: String.t() | nil,
          tickera_start_date: DateTime.t() | nil,
          tickera_end_date: DateTime.t() | nil,
          mobile_access_secret_encrypted: String.t() | nil,
          status: String.t() | nil,
          total_tickets: integer() | nil,
          checked_in_count: integer() | nil,
          attendee_count: integer() | nil,
          event_date: Date.t() | nil,
          event_time: Time.t() | nil,
          location: String.t() | nil,
          entrance_name: String.t() | nil,
          sync_started_at: DateTime.t() | nil,
          sync_completed_at: DateTime.t() | nil,
          last_sync_at: DateTime.t() | nil,
          last_soft_sync_at: DateTime.t() | nil,
          last_checked_at: DateTime.t() | nil,
          last_config_sync: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "events" do
    # Human readable name, e.g. "Voelgoed Live 13 November"
    field :name, :string
    # API key provided by Tickera (stored encrypted in the database)
    field :tickera_api_key_encrypted, :string
    field :tickera_api_key_last4, :string
    field :mobile_access_secret_encrypted, :string
    # URL of the WordPress site hosting Tickera
    field :tickera_site_url, :string
    field :tickera_start_date, :utc_datetime
    field :tickera_end_date, :utc_datetime
    # Event lifecycle status such as "active", "syncing", or "archived"
    field :status, :string
    # Total number of tickets made available for the event
    field :total_tickets, :integer
    # Number of tickets already checked in at the entrance
    field :checked_in_count, :integer
    # Virtual count of attendees loaded via aggregate queries
    field :attendee_count, :integer, virtual: true
    # Calendar date when the event takes place
    field :event_date, :date
    # Local time that gates open or the show starts
    field :event_time, :time
    # Location description, venue name, or address
    field :location, :string
    # Entrance identifier to route scanners (Main Entrance, VIP, etc.)
    field :entrance_name, :string
    # Timestamp of when a sync job last started
    field :sync_started_at, :utc_datetime
    # Timestamp of when a sync job successfully completed
    field :sync_completed_at, :utc_datetime
    field :last_sync_at, :utc_datetime
    field :last_soft_sync_at, :utc_datetime
    # Timestamp of the last attendee check-in action
    field :last_checked_at, :utc_datetime
    field :last_config_sync, :utc_datetime

    # Relationship to all attendees belonging to the event
    has_many :attendees, FastCheck.Attendees.Attendee

    # inserted_at/updated_at timestamps for auditing changes
    timestamps()
  end

  @doc """
  Builds an event changeset for create/update operations, validating required
  fields and ensuring Tickera credentials are stored in their encrypted
  columns.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :name,
      :tickera_api_key_encrypted,
      :tickera_api_key_last4,
      :mobile_access_secret_encrypted,
      :tickera_site_url,
      :tickera_start_date,
      :tickera_end_date,
      :status,
      :entrance_name,
      :event_date,
      :event_time,
      :location,
      :last_sync_at,
      :last_soft_sync_at
    ])
    |> validate_required([:name, :tickera_api_key_encrypted, :tickera_site_url])
  end
end
