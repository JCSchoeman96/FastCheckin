defmodule FastCheck.Repo.Migrations.ConvertTickeraEventWindowToUtc do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS tickera_start_date timestamptz")
    execute("ALTER TABLE events ADD COLUMN IF NOT EXISTS tickera_end_date timestamptz")

    execute("""
    ALTER TABLE events
      ALTER COLUMN tickera_start_date TYPE timestamptz
      USING (tickera_start_date AT TIME ZONE 'UTC')
    """)

    execute("""
    ALTER TABLE events
      ALTER COLUMN tickera_end_date TYPE timestamptz
      USING (tickera_end_date AT TIME ZONE 'UTC')
    """)
  end

  def down do
    execute("""
    ALTER TABLE events
      ALTER COLUMN tickera_start_date TYPE timestamp without time zone
      USING (tickera_start_date AT TIME ZONE 'UTC')
    """)

    execute("""
    ALTER TABLE events
      ALTER COLUMN tickera_end_date TYPE timestamp without time zone
      USING (tickera_end_date AT TIME ZONE 'UTC')
    """)
  end
end
