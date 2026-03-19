defmodule FastCheck.Repo.Migrations.CreateScanAttemptsAndObanJobs do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()

    create table(:scan_attempts) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:attendee_id, references(:attendees, on_delete: :nilify_all))
      add(:idempotency_key, :string, null: false)
      add(:ticket_code, :string, null: false)
      add(:direction, :string, null: false)
      add(:status, :string, null: false)
      add(:reason_code, :string)
      add(:message, :text)
      add(:entrance_name, :string)
      add(:operator_name, :string)
      add(:scanned_at, :utc_datetime)
      add(:processed_at, :utc_datetime, null: false)
      add(:hot_state_version, :string)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:scan_attempts, [:event_id, :idempotency_key],
        name: :scan_attempts_event_idempotency_key_idx
      )
    )

    create(index(:scan_attempts, [:event_id], name: :scan_attempts_event_idx))
    create(index(:scan_attempts, [:attendee_id], name: :scan_attempts_attendee_idx))
    create(index(:scan_attempts, [:processed_at], name: :scan_attempts_processed_at_idx))
  end

  def down do
    drop_if_exists(index(:scan_attempts, [:processed_at], name: :scan_attempts_processed_at_idx))
    drop_if_exists(index(:scan_attempts, [:attendee_id], name: :scan_attempts_attendee_idx))
    drop_if_exists(index(:scan_attempts, [:event_id], name: :scan_attempts_event_idx))

    drop_if_exists(
      unique_index(:scan_attempts, [:event_id, :idempotency_key],
        name: :scan_attempts_event_idempotency_key_idx
      )
    )

    drop_if_exists(table(:scan_attempts))

    Oban.Migrations.down()
  end
end
