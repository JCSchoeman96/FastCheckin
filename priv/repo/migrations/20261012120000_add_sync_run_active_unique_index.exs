defmodule FastCheck.Repo.Migrations.AddSyncRunActiveUniqueIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create(
      unique_index(:sync_logs, [:event_id],
        name: "sync_logs_one_active_run_per_event_index",
        concurrently: true,
        where: "status IN ('in_progress', 'paused')"
      )
    )
  end

  def down do
    drop(
      index(:sync_logs, [:event_id],
        name: "sync_logs_one_active_run_per_event_index",
        concurrently: true
      )
    )
  end
end
