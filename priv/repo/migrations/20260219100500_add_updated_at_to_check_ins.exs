defmodule FastCheck.Repo.Migrations.AddUpdatedAtToCheckIns do
  use Ecto.Migration

  def change do
    alter table(:check_ins) do
      add_if_not_exists(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end
  end
end
