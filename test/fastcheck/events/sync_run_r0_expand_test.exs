defmodule FastCheck.Events.SyncRunR0ExpandTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Events.SyncLog
  alias FastCheck.Repo

  test "ownership columns are nullable UUID and timestamptz columns" do
    columns =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'sync_logs'
        AND column_name IN (
          'sync_run_id', 'owner_token', 'lease_expires_at', 'heartbeat_at'
        )
      ORDER BY column_name
      """).rows

    assert columns == [
             ["heartbeat_at", "timestamp with time zone", "YES", nil],
             ["lease_expires_at", "timestamp with time zone", "YES", nil],
             ["owner_token", "uuid", "YES", nil],
             ["sync_run_id", "uuid", "YES", nil]
           ]
  end

  test "SyncLog represents the ownership columns without exposing them to the legacy changeset" do
    fields = SyncLog.__schema__(:fields)

    assert :sync_run_id in fields
    assert :owner_token in fields
    assert :lease_expires_at in fields
    assert :heartbeat_at in fields
    assert SyncLog.__schema__(:type, :sync_run_id) == Ecto.UUID
    assert SyncLog.__schema__(:type, :owner_token) == Ecto.UUID
    assert SyncLog.__schema__(:type, :lease_expires_at) == :utc_datetime_usec
    assert SyncLog.__schema__(:type, :heartbeat_at) == :utc_datetime_usec

    changeset =
      SyncLog.changeset(%SyncLog{}, %{
        event_id: 1,
        started_at: DateTime.utc_now(),
        status: "in_progress",
        sync_run_id: Ecto.UUID.generate(),
        owner_token: Ecto.UUID.generate(),
        lease_expires_at: DateTime.utc_now(),
        heartbeat_at: DateTime.utc_now()
      })

    refute Map.has_key?(changeset.changes, :sync_run_id)
    refute Map.has_key?(changeset.changes, :owner_token)
    refute Map.has_key?(changeset.changes, :lease_expires_at)
    refute Map.has_key?(changeset.changes, :heartbeat_at)
  end

  test "legacy log_sync_start persists an active row with null ownership" do
    event = create_event()

    assert {:ok, sync_log} = SyncLog.log_sync_start(event.id)

    assert [["in_progress", nil, nil, nil, nil]] =
             Repo.query!(
               """
               SELECT status, sync_run_id, owner_token, lease_expires_at, heartbeat_at
               FROM sync_logs
               WHERE id = $1
               """,
               [sync_log.id]
             ).rows
  end

  test "legacy writers may create multiple active rows for one event with null ownership" do
    event = create_event()

    assert {:ok, first} = SyncLog.log_sync_start(event.id)
    assert {:ok, second} = SyncLog.log_sync_start(event.id)

    assert first.id != second.id

    assert [[2]] =
             Repo.query!(
               """
               SELECT count(*)::integer
               FROM sync_logs
               WHERE event_id = $1
                 AND status IN ('in_progress', 'paused')
                 AND sync_run_id IS NULL
                 AND owner_token IS NULL
                 AND lease_expires_at IS NULL
                 AND heartbeat_at IS NULL
               """,
               [event.id]
             ).rows
  end

  test "non-null sync_run_id values are unique while null identities remain allowed" do
    event = create_event()
    run_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    insert_owned_run!(event.id, run_id)
    insert_owned_run!(event.id, nil)
    insert_owned_run!(event.id, nil)

    assert_raise Postgrex.Error, ~r/sync_logs_sync_run_id_unique_index/, fn ->
      insert_owned_run!(event.id, run_id)
    end
  end

  test "sync_run_id index is valid and ready" do
    assert [[indexdef, true, true]] =
             Repo.query!("""
             SELECT pg_get_indexdef(index_row.oid), index_state.indisvalid, index_state.indisready
             FROM pg_class AS table_row
             JOIN pg_namespace AS schema_row ON schema_row.oid = table_row.relnamespace
             JOIN pg_index AS index_state ON index_state.indrelid = table_row.oid
             JOIN pg_class AS index_row ON index_row.oid = index_state.indexrelid
             WHERE schema_row.nspname = 'public'
               AND table_row.relname = 'sync_logs'
               AND index_row.relname = 'sync_logs_sync_run_id_unique_index'
             """).rows

    normalized = String.downcase(indexdef)
    assert normalized =~ "create unique index"
    assert normalized =~ "(sync_run_id)"
    assert normalized =~ "where (sync_run_id is not null)"
  end

  test "concurrent indexes use separate migrations without disabling migration locking" do
    index_migrations =
      Path.wildcard("priv/repo/migrations/*sync_run*index*.exs")
      |> Map.new(fn path -> {path, File.read!(path)} end)

    sync_run_migrations =
      Enum.filter(index_migrations, fn {_path, contents} ->
        contents =~ "sync_logs_sync_run_id_unique_index"
      end)

    lease_migrations =
      Enum.filter(index_migrations, fn {_path, contents} ->
        contents =~ "sync_logs_active_lease_expiry_index"
      end)

    assert [{sync_run_path, sync_run_contents}] = sync_run_migrations
    assert [{lease_path, lease_contents}] = lease_migrations
    refute sync_run_path == lease_path

    for contents <- [sync_run_contents, lease_contents] do
      assert contents =~ "@disable_ddl_transaction true"
      refute contents =~ "@disable_migration_lock true"
      refute contents =~ "IF NOT EXISTS"
    end
  end

  test "lease recovery index covers expiry and id for active leased rows only" do
    assert [[indexdef, true, true]] =
             Repo.query!("""
             SELECT pg_get_indexdef(index_row.oid), index_state.indisvalid, index_state.indisready
             FROM pg_class AS table_row
             JOIN pg_namespace AS schema_row ON schema_row.oid = table_row.relnamespace
             JOIN pg_index AS index_state ON index_state.indrelid = table_row.oid
             JOIN pg_class AS index_row ON index_row.oid = index_state.indexrelid
             WHERE schema_row.nspname = 'public'
               AND table_row.relname = 'sync_logs'
               AND index_row.relname = 'sync_logs_active_lease_expiry_index'
             """).rows

    normalized = String.downcase(indexdef)
    assert normalized =~ "(lease_expires_at, id)"
    assert normalized =~ "in_progress"
    assert normalized =~ "paused"
    assert normalized =~ "lease_expires_at is not null"
  end

  test "R0 does not install active-run ownership enforcement" do
    assert [] ==
             Repo.query!("""
             SELECT indexname
             FROM pg_indexes
             WHERE schemaname = 'public'
               AND tablename = 'sync_logs'
               AND indexname = 'sync_logs_one_active_run_per_event_index'
             """).rows

    check_constraints =
      Repo.query!("""
      SELECT pg_get_constraintdef(constraint_row.oid)
      FROM pg_constraint AS constraint_row
      JOIN pg_class AS table_row ON table_row.oid = constraint_row.conrelid
      JOIN pg_namespace AS schema_row ON schema_row.oid = table_row.relnamespace
      WHERE schema_row.nspname = 'public'
        AND table_row.relname = 'sync_logs'
        AND constraint_row.contype = 'c'
      """).rows

    refute Enum.any?(check_constraints, fn [definition] ->
             definition =~ "sync_run_id" or definition =~ "owner_token" or
               definition =~ "lease_expires_at" or definition =~ "heartbeat_at"
           end)
  end

  defp insert_owned_run!(event_id, sync_run_id) do
    Repo.query!(
      """
      INSERT INTO sync_logs (event_id, started_at, status, sync_run_id, inserted_at, updated_at)
      VALUES ($1, now(), 'in_progress', $2, now(), now())
      """,
      [event_id, sync_run_id]
    )
  end
end
