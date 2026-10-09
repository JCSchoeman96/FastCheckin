defmodule FastCheck.Repo.Migrations.AddSyncRunExpandIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS sync_logs_sync_run_id_unique_index
    ON sync_logs (sync_run_id)
    WHERE sync_run_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS sync_logs_active_lease_expiry_index
    ON sync_logs (lease_expires_at, id)
    WHERE status IN ('in_progress', 'paused')
      AND lease_expires_at IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS sync_logs_active_lease_expiry_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS sync_logs_sync_run_id_unique_index")
  end
end
