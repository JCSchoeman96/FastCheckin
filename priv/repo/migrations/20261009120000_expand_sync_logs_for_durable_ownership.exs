defmodule FastCheck.Repo.Migrations.ExpandSyncLogsForDurableOwnership do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE sync_logs
      ADD COLUMN sync_run_id uuid,
      ADD COLUMN owner_token uuid,
      ADD COLUMN lease_expires_at timestamptz,
      ADD COLUMN heartbeat_at timestamptz
    """)
  end

  def down do
    execute("""
    ALTER TABLE sync_logs
      DROP COLUMN heartbeat_at,
      DROP COLUMN lease_expires_at,
      DROP COLUMN owner_token,
      DROP COLUMN sync_run_id
    """)
  end
end
