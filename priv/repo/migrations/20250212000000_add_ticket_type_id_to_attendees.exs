defmodule FastCheck.Repo.Migrations.AddTicketTypeIdToAttendees do
  use Ecto.Migration

  @add_column "ALTER TABLE attendees ADD COLUMN IF NOT EXISTS ticket_type_id integer"
  @drop_column "ALTER TABLE attendees DROP COLUMN IF EXISTS ticket_type_id"
  @create_index "CREATE INDEX IF NOT EXISTS idx_attendees_event_ticket_type_id ON attendees (event_id, ticket_type_id)"
  @drop_index "DROP INDEX IF EXISTS idx_attendees_event_ticket_type_id"

  def up do
    execute(@add_column)
    execute(@create_index)
  end

  def down do
    execute(@drop_index)
    execute(@drop_column)
  end
end
