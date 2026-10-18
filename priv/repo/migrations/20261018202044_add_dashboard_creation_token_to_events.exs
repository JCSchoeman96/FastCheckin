defmodule FastCheck.Repo.Migrations.AddDashboardCreationTokenToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add(:dashboard_creation_token, :uuid)
    end

    create(
      unique_index(:events, [:dashboard_creation_token],
        name: :events_dashboard_creation_token_uidx,
        where: "dashboard_creation_token IS NOT NULL"
      )
    )
  end
end
