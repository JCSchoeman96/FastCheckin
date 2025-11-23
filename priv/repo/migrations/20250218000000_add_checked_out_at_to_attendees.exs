defmodule FastCheck.Repo.Migrations.AddCheckedOutAtToAttendees do
  use Ecto.Migration

  def change do
    alter table(:attendees) do
      add(:checked_out_at, :utc_datetime)
    end

    create(index(:attendees, [:event_id, :checked_out_at], name: :idx_attendees_checked_out))
  end
end
