defmodule FastCheck.Repo.Migrations.AddSyncRunActiveOwnershipConstraint do
  use Ecto.Migration

  # Commit the brief ADD CONSTRAINT lock before PostgreSQL scans rows during
  # VALIDATE CONSTRAINT.
  @disable_ddl_transaction true

  def up do
    execute("""
    ALTER TABLE sync_logs
    ADD CONSTRAINT sync_logs_active_ownership_fields_check
    CHECK (
      status NOT IN ('in_progress', 'paused')
      OR (
        sync_run_id IS NOT NULL
        AND owner_token IS NOT NULL
        AND heartbeat_at IS NOT NULL
        AND lease_expires_at IS NOT NULL
      )
    ) NOT VALID
    """)

    execute("""
    ALTER TABLE sync_logs
    VALIDATE CONSTRAINT sync_logs_active_ownership_fields_check
    """)
  end

  def down do
    execute("""
    ALTER TABLE sync_logs
    DROP CONSTRAINT sync_logs_active_ownership_fields_check
    """)
  end
end
