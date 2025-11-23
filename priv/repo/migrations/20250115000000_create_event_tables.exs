defmodule FastCheck.Repo.Migrations.CreateEventTables do
  use Ecto.Migration

  def change do
    # Events hold the configuration for each Tickera-powered event that FastCheck can manage.
    create table(:events) do
      add(:name, :string, size: 255, null: false)
      add(:api_key, :string, size: 255, null: false)
      add(:site_url, :string, size: 255, null: false)
      add(:status, :string, size: 50, default: "active")
      add(:total_tickets, :integer, default: 0)
      add(:checked_in_count, :integer, default: 0)
      add(:event_date, :date)
      add(:event_time, :time)
      add(:location, :string, size: 255)
      add(:entrance_name, :string, size: 100)
      add(:sync_started_at, :utc_datetime)
      add(:sync_completed_at, :utc_datetime)
      add(:last_checked_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create(unique_index(:events, [:api_key], name: :idx_events_api_key))
    create(index(:events, [:status], name: :idx_events_status))

    # Attendees represent individual ticket holders synced from Tickera for each event.
    create table(:attendees) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:ticket_code, :string, size: 255, null: false)
      add(:first_name, :string, size: 100)
      add(:last_name, :string, size: 100)
      add(:email, :string, size: 255)
      add(:ticket_type, :string, size: 100)
      add(:allowed_checkins, :integer, default: 1)
      add(:checkins_remaining, :integer, default: 1)
      add(:payment_status, :string, size: 50)
      add(:custom_fields, :map)
      add(:checked_in_at, :utc_datetime)
      add(:last_checked_in_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create(unique_index(:attendees, [:event_id, :ticket_code], name: :idx_attendees_event_code))
    create(index(:attendees, [:event_id], name: :idx_attendees_event_id))
    create(index(:attendees, [:ticket_code], name: :idx_attendees_ticket_code))
    create(index(:attendees, [:event_id, :checked_in_at], name: :idx_attendees_checked_in))

    # Check-ins store the immutable audit trail every time a QR code is scanned at an event.
    create table(:check_ins) do
      add(:attendee_id, references(:attendees, on_delete: :delete_all), null: false)
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:ticket_code, :string, size: 255, null: false)
      add(:checked_in_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:entrance_name, :string, size: 100)
      add(:operator_name, :string, size: 100)
      add(:status, :string, size: 50)
      add(:notes, :text)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create(index(:check_ins, [:event_id], name: :idx_check_ins_event_id))
    create(index(:check_ins, [:attendee_id], name: :idx_check_ins_attendee_id))
    create(index(:check_ins, [:checked_in_at], name: :idx_check_ins_checked_in_at))
    create(index(:check_ins, [:entrance_name], name: :idx_check_ins_entrance))
  end
end
