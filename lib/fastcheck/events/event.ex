defmodule FastCheck.Events.Event do
  @moduledoc """
  Defines the Event schema which stores metadata about every synced Tickera event
  including its status, entrance configuration, and sync timestamps.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          api_key: String.t() | nil,
          site_url: String.t() | nil,
          status: String.t() | nil,
          total_tickets: integer() | nil,
          checked_in_count: integer() | nil,
          event_date: Date.t() | nil,
          event_time: Time.t() | nil,
          location: String.t() | nil,
          entrance_name: String.t() | nil,
          sync_started_at: DateTime.t() | nil,
          sync_completed_at: DateTime.t() | nil,
          last_checked_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "events" do
    # Human readable name, e.g. "Voelgoed Live 13 November"
    field :name, :string
    # API key provided by Tickera for authenticating requests
    field :api_key, :string
    # URL of the WordPress site hosting Tickera
    field :site_url, :string
    # Event lifecycle status such as "active", "syncing", or "archived"
    field :status, :string
    # Total number of tickets made available for the event
    field :total_tickets, :integer
    # Number of tickets already checked in at the entrance
    field :checked_in_count, :integer
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
    # Timestamp of the last attendee check-in action
    field :last_checked_at, :utc_datetime

    # Relationship to all attendees belonging to the event
    has_many :attendees, FastCheck.Attendees.Attendee

    # inserted_at/updated_at timestamps for auditing changes
    timestamps()
  end

  @doc """
  Builds an event changeset for create/update operations, validating required
  fields and enforcing API key uniqueness per event.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:name, :api_key, :site_url, :status, :entrance_name, :event_date, :event_time, :location])
    |> validate_required([:name, :api_key, :site_url])
    |> unique_constraint(:api_key)
  end
end
