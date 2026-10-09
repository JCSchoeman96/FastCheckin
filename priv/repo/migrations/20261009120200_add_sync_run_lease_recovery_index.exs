defmodule FastCheck.Repo.Migrations.AddSyncRunLeaseRecoveryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create(
      index(:sync_logs, [:lease_expires_at, :id],
        name: "sync_logs_active_lease_expiry_index",
        concurrently: true,
        where: "status IN ('in_progress', 'paused') AND lease_expires_at IS NOT NULL"
      )
    )
  end
end
