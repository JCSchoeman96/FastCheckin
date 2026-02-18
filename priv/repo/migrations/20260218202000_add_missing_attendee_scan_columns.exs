defmodule FastCheck.Repo.Migrations.AddMissingAttendeeScanColumns do
  use Ecto.Migration

  def change do
    alter table(:attendees) do
      add_if_not_exists(:daily_scan_count, :integer, default: 0)
      add_if_not_exists(:weekly_scan_count, :integer, default: 0)
      add_if_not_exists(:monthly_scan_count, :integer, default: 0)
      add_if_not_exists(:last_checked_in_date, :date)
      add_if_not_exists(:last_entrance, :string, size: 100)
      add_if_not_exists(:is_currently_inside, :boolean, default: false)
      add_if_not_exists(:checked_out_at, :utc_datetime)
    end

    create_if_not_exists(
      index(:attendees, [:event_id, :last_checked_in_date], name: :idx_attendees_event_last_checked_date)
    )
  end
end
