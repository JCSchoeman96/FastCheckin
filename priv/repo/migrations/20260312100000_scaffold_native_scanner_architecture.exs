defmodule FastCheck.Repo.Migrations.ScaffoldNativeScannerArchitecture do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add_if_not_exists(:scanner_policy_mode, :string, default: "online_required", null: false)
      add_if_not_exists(:config_version, :integer, default: 1, null: false)
    end

    execute("""
    ALTER TABLE events
    DROP CONSTRAINT IF EXISTS events_scanner_policy_mode_valid
    """)

    execute("""
    ALTER TABLE events
    ADD CONSTRAINT events_scanner_policy_mode_valid
    CHECK (scanner_policy_mode IN ('online_required', 'offline_capable'))
    """)

    alter table(:attendees) do
      add_if_not_exists(:normalized_code, :string)
    end

    execute("""
    UPDATE attendees
    SET normalized_code = UPPER(BTRIM(ticket_code))
    WHERE normalized_code IS NULL AND ticket_code IS NOT NULL
    """)

    create_if_not_exists(
      unique_index(:attendees, [:event_id, :normalized_code],
        name: :idx_attendees_event_normalized_code
      )
    )

    create_if_not_exists(
      index(:attendees, [:event_id, :payment_status], name: :idx_attendees_event_status)
    )

    create_if_not_exists table(:gates) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:status, :string, default: "active", null: false)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(unique_index(:gates, [:event_id, :slug], name: :idx_gates_event_slug))
    create_if_not_exists(index(:gates, [:event_id], name: :idx_gates_event_id))

    create_if_not_exists table(:devices) do
      add(:installation_id, :string, null: false)
      add(:platform, :string, default: "android", null: false)
      add(:label, :string)
      add(:app_version, :string)
      add(:status, :string, default: "provisioned", null: false)
      add(:last_seen_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      unique_index(:devices, [:installation_id], name: :idx_devices_installation_id)
    )

    create_if_not_exists(index(:devices, [:status], name: :idx_devices_status))

    create_if_not_exists table(:device_sessions) do
      add(:device_id, references(:devices, on_delete: :delete_all), null: false)
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:gate_id, references(:gates, on_delete: :nilify_all))
      add(:operator_name, :string)
      add(:app_version, :string)
      add(:last_seen_at, :utc_datetime)
      add(:expires_at, :utc_datetime, null: false)
      add(:revoked_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      index(:device_sessions, [:device_id, :revoked_at, :expires_at],
        name: :idx_device_sessions_device_revoked_expires
      )
    )

    create_if_not_exists(
      index(:device_sessions, [:event_id, :device_id, :revoked_at],
        name: :idx_device_sessions_event_device_revoked
      )
    )

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_device_sessions_active_device
    ON device_sessions (device_id)
    WHERE revoked_at IS NULL
    """)

    create_if_not_exists table(:sync_cursors) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:source, :string, null: false, default: "tickera")
      add(:cursor, :string)
      add(:last_synced_at, :utc_datetime)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      unique_index(:sync_cursors, [:event_id, :source], name: :idx_sync_cursors_event_source)
    )

    create_if_not_exists table(:offline_event_packages) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:version, :integer, null: false, default: 1)
      add(:status, :string, default: "draft", null: false)
      add(:checksum, :string)
      add(:generated_at, :utc_datetime)
      add(:expires_at, :utc_datetime)
      add(:metadata, :map)
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      unique_index(:offline_event_packages, [:event_id, :version],
        name: :idx_offline_event_packages_event_version
      )
    )

    alter table(:check_ins) do
      add_if_not_exists(:gate_id, references(:gates, on_delete: :nilify_all))
      add_if_not_exists(:device_id, references(:devices, on_delete: :nilify_all))
      add_if_not_exists(:device_session_id, references(:device_sessions, on_delete: :nilify_all))
      add_if_not_exists(:request_id, :string)
      add_if_not_exists(:decision, :string)
      add_if_not_exists(:reconciliation_state, :string)
      add_if_not_exists(:connectivity_mode, :string)
      add_if_not_exists(:scanned_at_device, :utc_datetime)
      add_if_not_exists(:app_version, :string)
      add_if_not_exists(:feedback_tone, :string)
      add_if_not_exists(:feedback_color, :string)
      add_if_not_exists(:display_name, :string)
      add_if_not_exists(:ticket_label, :string)
    end

    create_if_not_exists(
      index(:check_ins, [:event_id, :inserted_at], name: :idx_check_ins_event_inserted_at)
    )

    create_if_not_exists(
      index(:check_ins, [:attendee_id, :inserted_at], name: :idx_check_ins_attendee_inserted_at)
    )
  end

  def down do
    drop_if_exists(
      index(:check_ins, [:attendee_id, :inserted_at], name: :idx_check_ins_attendee_inserted_at)
    )

    drop_if_exists(
      index(:check_ins, [:event_id, :inserted_at], name: :idx_check_ins_event_inserted_at)
    )

    alter table(:check_ins) do
      remove_if_exists(:ticket_label)
      remove_if_exists(:display_name)
      remove_if_exists(:feedback_color)
      remove_if_exists(:feedback_tone)
      remove_if_exists(:app_version)
      remove_if_exists(:scanned_at_device)
      remove_if_exists(:connectivity_mode)
      remove_if_exists(:reconciliation_state)
      remove_if_exists(:decision)
      remove_if_exists(:request_id)
      remove_if_exists(:device_session_id)
      remove_if_exists(:device_id)
      remove_if_exists(:gate_id)
    end

    drop_if_exists(
      index(:offline_event_packages, [:event_id, :version],
        name: :idx_offline_event_packages_event_version
      )
    )

    drop_if_exists(table(:offline_event_packages))

    drop_if_exists(
      index(:sync_cursors, [:event_id, :source], name: :idx_sync_cursors_event_source)
    )

    drop_if_exists(table(:sync_cursors))
    execute("DROP INDEX IF EXISTS idx_device_sessions_active_device")

    drop_if_exists(
      index(:device_sessions, [:event_id, :device_id, :revoked_at],
        name: :idx_device_sessions_event_device_revoked
      )
    )

    drop_if_exists(
      index(:device_sessions, [:device_id, :revoked_at, :expires_at],
        name: :idx_device_sessions_device_revoked_expires
      )
    )

    drop_if_exists(table(:device_sessions))
    drop_if_exists(index(:devices, [:status], name: :idx_devices_status))
    drop_if_exists(index(:devices, [:installation_id], name: :idx_devices_installation_id))
    drop_if_exists(table(:devices))
    drop_if_exists(index(:gates, [:event_id], name: :idx_gates_event_id))
    drop_if_exists(index(:gates, [:event_id, :slug], name: :idx_gates_event_slug))
    drop_if_exists(table(:gates))

    drop_if_exists(
      index(:attendees, [:event_id, :payment_status], name: :idx_attendees_event_status)
    )

    drop_if_exists(
      index(:attendees, [:event_id, :normalized_code], name: :idx_attendees_event_normalized_code)
    )

    alter table(:attendees) do
      remove_if_exists(:normalized_code)
    end

    execute("""
    ALTER TABLE events
    DROP CONSTRAINT IF EXISTS events_scanner_policy_mode_valid
    """)

    alter table(:events) do
      remove_if_exists(:config_version)
      remove_if_exists(:scanner_policy_mode)
    end
  end
end
