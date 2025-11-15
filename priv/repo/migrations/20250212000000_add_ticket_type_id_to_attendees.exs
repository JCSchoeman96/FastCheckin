defmodule FastCheck.Repo.Migrations.AddTicketTypeIdToAttendees do
  use Ecto.Migration

  def change do
    alter table(:attendees) do
      add :ticket_type_id, :integer
    end

    create index(:attendees, [:event_id, :ticket_type_id], name: :idx_attendees_event_ticket_type_id)
  end
end
