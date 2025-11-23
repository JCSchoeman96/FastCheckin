defmodule FastCheck.Repo.Migrations.CreateCheckInConfigurations do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist", "DROP EXTENSION IF EXISTS btree_gist")

    create table(:check_in_configurations) do
      add(:event_id, references(:events, on_delete: :delete_all), null: false)
      add(:ticket_type_id, :integer, null: false)
      add(:ticket_type, :string)
      add(:ticket_name, :string)
      add(:allowed_checkins, :integer, default: 1)
      add(:allow_reentry, :boolean, default: false)
      add(:allowed_entrances, :map)
      add(:check_in_window_start, :date)
      add(:check_in_window_end, :date)
      add(:check_in_window_timezone, :string)
      add(:check_in_window_days, :integer)
      add(:check_in_window_buffer_minutes, :integer)
      add(:time_basis, :string)
      add(:time_basis_timezone, :string)
      add(:daily_check_in_limit, :integer)
      add(:entrance_limit, :integer)
      add(:limit_per_order, :integer)
      add(:min_per_order, :integer)
      add(:max_per_order, :integer)
      add(:status, :string)
      add(:message, :text)
      add(:last_checked_in_date, :date)

      timestamps()
    end

    create(
      unique_index(:check_in_configurations, [:event_id, :ticket_type_id],
        name: :idx_configs_event_ticket_type
      )
    )

    create(index(:check_in_configurations, [:time_basis], name: :idx_configs_time_basis))

    create(
      index(:check_in_configurations, [:last_checked_in_date],
        name: :idx_configs_last_checked_in_date
      )
    )

    alter table(:events) do
      add(:last_config_sync, :utc_datetime)
    end

    create(index(:events, [:last_config_sync], name: :idx_events_last_config_sync))
  end
end
