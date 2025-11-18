defmodule FastCheck.Repo.Migrations.AddTickeraFieldsToEvents do
  use Ecto.Migration

  @status_constraint "events_status_must_be_valid"

  def up do
    execute("""
    UPDATE events
       SET status = 'active'
     WHERE status IS NULL
        OR btrim(status) = ''
        OR status NOT IN ('active','syncing','archived')
    """)

    alter table(:events) do
      add :tickera_site_url, :string, size: 255
      add :tickera_api_key_encrypted, :text
      add :tickera_api_key_last4, :string, size: 4
      add :tickera_start_date, :naive_datetime
      add :tickera_end_date, :naive_datetime
      add :last_sync_at, :utc_datetime
      add :last_soft_sync_at, :utc_datetime, null: true
      modify :status, :string, size: 50, null: false, default: "active"
    end

    create constraint(:events, @status_constraint, check: "status IN ('active','syncing','archived')")

    execute("UPDATE events SET tickera_site_url = site_url WHERE tickera_site_url IS NULL")

    execute("""
    UPDATE events
       SET tickera_api_key_last4 = RIGHT(api_key, 4)
     WHERE api_key IS NOT NULL
       AND (tickera_api_key_last4 IS NULL OR tickera_api_key_last4 = '')
    """)
  end

  def down do
    drop constraint(:events, @status_constraint)

    alter table(:events) do
      remove :tickera_site_url
      remove :tickera_api_key_encrypted
      remove :tickera_api_key_last4
      remove :tickera_start_date
      remove :tickera_end_date
      remove :last_sync_at
      remove :last_soft_sync_at
      modify :status, :string, size: 50, null: true, default: "active"
    end
  end
end
