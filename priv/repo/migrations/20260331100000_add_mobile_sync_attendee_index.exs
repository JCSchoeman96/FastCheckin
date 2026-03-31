defmodule FastCheck.Repo.Migrations.AddMobileSyncAttendeeIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name "idx_attendees_event_updated_at_id"

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index_name}
    ON attendees (event_id, updated_at, id)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS #{@index_name}
    """)
  end
end
