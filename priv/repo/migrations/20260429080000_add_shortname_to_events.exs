defmodule FastCheck.Repo.Migrations.AddShortnameToEvents do
  use Ecto.Migration

  def change do
    alter table(:events) do
      add(:shortname, :string)
    end

    create(
      unique_index(:events, [:shortname],
        name: :idx_events_shortname,
        where: "shortname IS NOT NULL"
      )
    )
  end
end
