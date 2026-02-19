defmodule FastCheck.Repo.Migrations.AddEntranceNameToCheckInSessions do
  use Ecto.Migration

  def change do
    alter table(:check_in_sessions) do
      add_if_not_exists(:entrance_name, :string, size: 100)
    end
  end
end
