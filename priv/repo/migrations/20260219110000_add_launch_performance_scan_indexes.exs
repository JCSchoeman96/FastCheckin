defmodule FastCheck.Repo.Migrations.AddLaunchPerformanceScanIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_check_in_sessions_event_attendee_active
    ON check_in_sessions (event_id, attendee_id)
    WHERE exit_time IS NULL
    """)

    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS idx_attendees_event_checked
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS idx_check_in_sessions_event_attendee_active
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_attendees_event_checked
    ON attendees (event_id, checked_in_at)
    """)
  end
end
