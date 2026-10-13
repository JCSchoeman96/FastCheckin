defmodule FastCheck.Repo.Migrations.AddSyncRunActiveOwnershipConstraint do
  @moduledoc """
  Add the active-run ownership check without validating existing rows.

  Validation runs in the next migration version so an operator can reconcile
  unexpected active rows and retry validation without repeating this add.
  """
  use Ecto.Migration

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

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
      )
      NOT VALID
    """)
  end

  def down do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE sync_logs
      DROP CONSTRAINT IF EXISTS sync_logs_active_ownership_fields_check
    """)
  end
end
