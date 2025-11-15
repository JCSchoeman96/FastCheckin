defmodule PetalBlueprint.Repo.Migrations.CreateIndexesOptimization do
  use Ecto.Migration

  @managed_comment "created_by_migration_20250206000000"

  def up do
    ensure_index(:attendees, [:event_id, :checked_in_at], :idx_attendees_event_checked)
    ensure_index(:attendees, [:event_id, :ticket_code], :idx_attendees_event_code)
    ensure_index(:check_ins, [:entrance_name], :idx_check_ins_entrance)
  end

  def down do
    drop_managed_index(:idx_attendees_event_checked)
    drop_managed_index(:idx_attendees_event_code)
    drop_managed_index(:idx_check_ins_entrance)
  end

  defp ensure_index(table, columns, name) do
    table_sql = Atom.to_string(table)
    index_sql = Atom.to_string(name)
    columns_sql =
      columns
      |> Enum.map(&"\"#{Atom.to_string(&1)}\"")
      |> Enum.join(", ")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_class WHERE relname = '#{index_sql}' AND relkind = 'i'
      ) THEN
        EXECUTE 'CREATE INDEX #{index_sql} ON #{table_sql} (#{columns_sql})';
        EXECUTE 'COMMENT ON INDEX #{index_sql} IS ''#{@managed_comment}''';
      END IF;
    END;
    $$;
    """)
  end

  defp drop_managed_index(name) do
    index_sql = Atom.to_string(name)

    execute("""
    DO $$
    DECLARE
      idx_oid oid;
      idx_comment text;
    BEGIN
      SELECT c.oid, d.description
      INTO idx_oid, idx_comment
      FROM pg_class c
      LEFT JOIN pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_class'::regclass
      WHERE c.relname = '#{index_sql}' AND c.relkind = 'i';

      IF idx_oid IS NOT NULL AND idx_comment = '#{@managed_comment}' THEN
        EXECUTE 'DROP INDEX IF EXISTS #{index_sql}';
      END IF;
    END;
    $$;
    """)
  end
end
