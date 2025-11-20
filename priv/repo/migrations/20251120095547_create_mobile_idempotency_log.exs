defmodule FastCheck.Repo.Migrations.CreateMobileIdempotencyLog do
  use Ecto.Migration

  def change do
    # Mobile idempotency log ensures each scan from the mobile client is processed
    # at most once per event, even under retries or network issues. This table is
    # write-heavy and read-light: each unique scan inserts a row; duplicates hit
    # the unique index and are treated as already processed.
    create table(:mobile_idempotency_log) do
      add :idempotency_key, :string, size: 255, null: false
      add :event_id, references(:events, on_delete: :restrict), null: false
      add :ticket_code, :string, size: 255, null: false
      add :result, :string, size: 50, null: false
      add :metadata, :map

      timestamps(type: :utc_datetime)
    end

    # Unique constraint ensures idempotency: same key for same event can only be inserted once
    create unique_index(:mobile_idempotency_log, [:event_id, :idempotency_key],
             name: :idx_mobile_idempotency_event_key
           )

    # Additional index for lookups by event
    create index(:mobile_idempotency_log, [:event_id], name: :idx_mobile_idempotency_event)
  end
end
