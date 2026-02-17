defmodule FastCheck.Repo.Migrations.CreateSyncLogs do
  use Ecto.Migration

  def change do
    create table(:sync_logs) do
      add :event_id, references(:events, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime, null: false
      add :completed_at, :utc_datetime
      add :status, :string, null: false
      add :attendees_synced, :integer, default: 0
      add :total_pages, :integer
      add :pages_processed, :integer, default: 0
      add :error_message, :text
      add :duration_ms, :integer

      timestamps()
    end

    create index(:sync_logs, [:event_id])
    create index(:sync_logs, [:started_at])
    create index(:sync_logs, [:status])
    create index(:sync_logs, [:event_id, :started_at])
  end
end
