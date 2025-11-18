defmodule FastCheck.Repo.Migrations.AddCriticalIndexes do
  use Ecto.Migration

  def change do
    create_if_not_exists(unique_index(:attendees, [:event_id, :ticket_code], name: :idx_attendees_event_code))

    create_if_not_exists(index(:attendees, [:event_id, :checked_in_at], name: :idx_attendees_event_checked))

    create_if_not_exists(index(:attendees, [:event_id, :is_currently_inside], name: :idx_attendees_event_inside))

    create_if_not_exists(index(:check_ins, [:event_id, :entrance_name, :checked_in_at],
      name: :idx_check_ins_event_entrance_checked_in
    ))

    create_if_not_exists(index(:check_ins, [:event_id, :status, :checked_in_at],
      name: :idx_check_ins_event_status_checked_in
    ))

    create_if_not_exists(index(:check_in_sessions, [:attendee_id, :exit_time],
      name: :idx_check_in_sessions_attendee_exit_time
    ))
  end
end
