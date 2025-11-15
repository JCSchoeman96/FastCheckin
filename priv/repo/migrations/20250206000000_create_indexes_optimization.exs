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
    table_sql = qualified_table(table)
    index_sql = Atom.to_string(name)
    index_identifier = qualified_index(name)
    columns_sql =
      columns
      |> Enum.map(&"\"#{Atom.to_string(&1)}\"")
      |> Enum.join(", ")

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = '#{index_sql}'
          AND n.nspname = #{schema_condition_sql()}
          AND c.relkind = 'i'
      ) THEN
        EXECUTE 'CREATE INDEX #{index_identifier} ON #{table_sql} (#{columns_sql})';
        EXECUTE 'COMMENT ON INDEX #{index_identifier} IS ''#{@managed_comment}''';
      END IF;
    END;
    $$;
    """)
  end

  defp drop_managed_index(name) do
    index_sql = Atom.to_string(name)
    index_identifier = qualified_index(name)

    execute("""
    DO $$
    DECLARE
      idx_oid oid;
      idx_comment text;
    BEGIN
      SELECT c.oid, d.description
      INTO idx_oid, idx_comment
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_class'::regclass
      WHERE c.relname = '#{index_sql}'
        AND n.nspname = #{schema_condition_sql()}
        AND c.relkind = 'i';

      IF idx_oid IS NOT NULL AND idx_comment = '#{@managed_comment}' THEN
        EXECUTE 'DROP INDEX IF EXISTS #{index_identifier}';
      END IF;
    END;
    $$;
    """)
  end

  defp qualified_table(table) do
    table_name = Atom.to_string(table)

    case prefix() do
      nil -> "\"#{table_name}\""
      schema -> "#{quote_ident(schema)}.\"#{table_name}\""
    end
  end

  defp qualified_index(name) do
    index_name = Atom.to_string(name)

    case prefix() do
      nil -> "\"#{index_name}\""
      schema -> "#{quote_ident(schema)}.\"#{index_name}\""
    end
  end

  defp schema_condition_sql do
    case prefix() do
      nil -> "current_schema()"
      schema -> "'#{escape_literal(schema)}'"
    end
  end

  defp quote_ident(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  defp escape_literal(value) do
    String.replace(value, "'", "''")
  end
end
