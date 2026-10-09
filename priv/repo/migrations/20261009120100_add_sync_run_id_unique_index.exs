defmodule FastCheck.Repo.Migrations.AddSyncRunIdUniqueIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create(
      unique_index(:sync_logs, [:sync_run_id],
        name: "sync_logs_sync_run_id_unique_index",
        concurrently: true,
        where: "sync_run_id IS NOT NULL"
      )
    )
  end
end
