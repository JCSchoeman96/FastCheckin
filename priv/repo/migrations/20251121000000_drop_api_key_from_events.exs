defmodule FastCheck.Repo.Migrations.DropApiKeyFromEvents do
  use Ecto.Migration

  def up do
    drop_if_exists(index(:events, [:api_key], name: :idx_events_api_key))

    alter table(:events) do
      remove(:api_key)
    end
  end

  def down do
    alter table(:events) do
      add(:api_key, :string, size: 255, null: true)
    end

    create(unique_index(:events, [:api_key], name: :idx_events_api_key))
  end
end
