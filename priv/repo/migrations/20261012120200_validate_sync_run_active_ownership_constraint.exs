defmodule FastCheck.Repo.Migrations.ValidateSyncRunActiveOwnershipConstraint do
  @moduledoc """
  Validate the active ownership check added by
  `20261012120100_add_sync_run_active_ownership_constraint`.

  Keeping validation in its own migration version lets operators reconcile
  unexpected rows and retry validation without re-running the constraint add.
  """
  use Ecto.Migration

  def up do
    repo().query!("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE sync_logs
      VALIDATE CONSTRAINT sync_logs_active_ownership_fields_check
    """)
  end

  def down do
    :ok
  end
end
