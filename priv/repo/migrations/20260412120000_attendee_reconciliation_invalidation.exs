defmodule FastCheck.Repo.Migrations.AttendeeReconciliationInvalidation do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add(:event_sync_version, :bigint, null: false, default: 0)
    end

    alter table(:attendees) do
      add(:scan_eligibility, :string, null: false, default: "active")
      add(:ineligibility_reason, :string)
      add(:ineligible_since, :utc_datetime)
      add(:source_last_seen_at, :utc_datetime)
      add(:last_authoritative_sync_run_id, :uuid)
    end

    create(
      constraint(:attendees, :scan_eligibility_valid,
        check: "scan_eligibility IN ('active', 'not_scannable')"
      )
    )

    create(
      index(:attendees, [:event_id, :scan_eligibility],
        name: :attendees_event_id_scan_eligibility_idx
      )
    )

    create table(:attendee_invalidation_events) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:attendee_id, references(:attendees, on_delete: :delete_all), null: false)
      add(:ticket_code, :string, null: false)
      add(:change_type, :string, null: false)
      add(:reason_code, :string, null: false)
      add(:effective_at, :utc_datetime, null: false)
      add(:source_sync_run_id, :uuid)

      timestamps(updated_at: false)
    end

    create(
      index(:attendee_invalidation_events, [:event_id, :id],
        name: :attendee_invalidation_events_event_id_id_idx
      )
    )

    create(
      index(:attendee_invalidation_events, [:event_id, :inserted_at],
        name: :attendee_invalidation_events_event_id_inserted_at_idx
      )
    )
  end

  def down do
    drop(
      index(:attendee_invalidation_events,
        name: :attendee_invalidation_events_event_id_inserted_at_idx
      )
    )

    drop(
      index(:attendee_invalidation_events, name: :attendee_invalidation_events_event_id_id_idx)
    )

    drop(table(:attendee_invalidation_events))

    drop(index(:attendees, name: :attendees_event_id_scan_eligibility_idx))
    drop(constraint(:attendees, :scan_eligibility_valid))

    alter table(:attendees) do
      remove(:last_authoritative_sync_run_id)
      remove(:source_last_seen_at)
      remove(:ineligible_since)
      remove(:ineligibility_reason)
      remove(:scan_eligibility)
    end

    alter table(:events) do
      remove(:event_sync_version)
    end
  end
end
