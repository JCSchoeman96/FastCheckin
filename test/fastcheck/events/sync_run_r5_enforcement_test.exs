defmodule FastCheck.Events.SyncRunR5EnforcementTest do
  use FastCheck.DataCase, async: false

  import FastCheck.Fixtures

  alias FastCheck.Events
  alias FastCheck.Events.{Sync, SyncLog, SyncRun}
  alias FastCheck.Repo

  test "the database rejects a second active row even when its status is paused" do
    event = create_event()
    insert_run!(event.id, "in_progress", owned_fields())

    error =
      assert_raise Ecto.ConstraintError, fn ->
        insert_run!(event.id, "paused", owned_fields())
      end

    assert error.constraint == "sync_logs_one_active_run_per_event_index"
  end

  test "the database treats paused runs as active for uniqueness" do
    event = create_event()
    insert_run!(event.id, "paused", owned_fields())

    error =
      assert_raise Ecto.ConstraintError, fn ->
        insert_run!(event.id, "in_progress", owned_fields())
      end

    assert error.constraint == "sync_logs_one_active_run_per_event_index"
  end

  test "terminal rows can coexist with active rows for an event" do
    event = create_event()
    insert_run!(event.id, "in_progress", owned_fields())

    for status <- ["completed", "failed", "cancelled"] do
      assert %SyncLog{status: ^status} = insert_run!(event.id, status, %{})
    end
  end

  test "an active row requires sync_run_id" do
    assert_active_ownership_field_required(:sync_run_id)
  end

  test "an active row requires owner_token" do
    assert_active_ownership_field_required(:owner_token)
  end

  test "an active row requires heartbeat_at" do
    assert_active_ownership_field_required(:heartbeat_at)
  end

  test "an active row requires lease_expires_at" do
    assert_active_ownership_field_required(:lease_expires_at)
  end

  test "terminal history with null ownership fields remains valid" do
    event = create_event()

    for status <- ["completed", "failed", "cancelled"] do
      assert %SyncLog{status: ^status} = insert_run!(event.id, status, %{})
    end
  end

  test "a valid owned active row inserts normally" do
    event = create_event()

    assert %SyncLog{status: "in_progress"} =
             insert_run!(event.id, "in_progress", owned_fields())
  end

  test "the partial unique index and ownership constraint are installed and validated" do
    assert [[index_definition, true, true]] =
             Repo.query!("""
             SELECT pg_get_indexdef(index_row.oid), index_state.indisvalid, index_state.indisready
             FROM pg_class AS table_row
             JOIN pg_index AS index_state ON index_state.indrelid = table_row.oid
             JOIN pg_class AS index_row ON index_row.oid = index_state.indexrelid
             WHERE table_row.relname = 'sync_logs'
               AND index_row.relname = 'sync_logs_one_active_run_per_event_index'
             """).rows

    normalized_index = String.downcase(index_definition)
    assert normalized_index =~ "(event_id)"
    assert normalized_index =~ "in_progress"
    assert normalized_index =~ "paused"

    assert [[constraint_definition, true]] =
             Repo.query!("""
             SELECT pg_get_constraintdef(constraint_row.oid), constraint_row.convalidated
             FROM pg_constraint AS constraint_row
             JOIN pg_class AS table_row ON table_row.oid = constraint_row.conrelid
             WHERE table_row.relname = 'sync_logs'
               AND constraint_row.conname = 'sync_logs_active_ownership_fields_check'
             """).rows

    for field <- ["sync_run_id", "owner_token", "heartbeat_at", "lease_expires_at"] do
      assert constraint_definition =~ field
    end
  end

  test "ownership constraint add and validation use separate transactional migrations" do
    add_migration =
      File.read!(
        "priv/repo/migrations/20261012120100_add_sync_run_active_ownership_constraint.exs"
      )

    validate_migration =
      File.read!(
        "priv/repo/migrations/20261012120200_validate_sync_run_active_ownership_constraint.exs"
      )

    assert add_migration =~ "SET LOCAL lock_timeout = '5s'"
    assert add_migration =~ "ADD CONSTRAINT sync_logs_active_ownership_fields_check"
    assert add_migration =~ "NOT VALID"
    refute add_migration =~ "VALIDATE CONSTRAINT"
    refute add_migration =~ "@disable_ddl_transaction true"
    refute add_migration =~ "@disable_migration_lock true"
    assert length(Regex.scan(~r/SET LOCAL lock_timeout = '5s'/, add_migration)) == 2
    assert add_migration =~ "DROP CONSTRAINT IF EXISTS sync_logs_active_ownership_fields_check"

    assert validate_migration =~ "SET LOCAL lock_timeout = '5s'"
    assert validate_migration =~ "VALIDATE CONSTRAINT sync_logs_active_ownership_fields_check"
    refute validate_migration =~ "@disable_ddl_transaction true"
    refute validate_migration =~ "@disable_migration_lock true"
  end

  test "claim concurrency still creates one active row per event" do
    event = create_event()
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :claim -> SyncRun.claim(event.id)
          end
        end)
      end

    for task <- tasks do
      assert_receive {:ready, pid}
      assert pid == task.pid
    end

    Enum.each(tasks, &send(&1.pid, :claim))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :sync_already_running})) == 1
  end

  test "public APIs do not export unguarded start or Event-ID-only reset" do
    Code.ensure_loaded!(Events)
    Code.ensure_loaded!(Sync)

    refute function_exported?(Events, :sync_event, 1)
    refute function_exported?(Events, :sync_event, 2)
    refute function_exported?(Events, :sync_event, 3)
    refute function_exported?(Events, :force_reset_sync, 1)
    refute function_exported?(Events, :force_reset_sync, 2)
    refute function_exported?(Sync, :sync_event, 1)
    refute function_exported?(Sync, :sync_event, 2)
    refute function_exported?(Sync, :sync_event, 3)
    refute function_exported?(Sync, :force_reset_sync, 1)
    refute function_exported?(Sync, :force_reset_sync, 2)
    refute function_exported?(SyncLog, :log_sync_start, 1)
    refute function_exported?(SyncLog, :log_sync_completion, 4)
    refute function_exported?(SyncLog, :log_sync_error, 3)
    refute function_exported?(SyncLog, :update_progress, 3)
  end

  defp assert_active_ownership_field_required(field) do
    event = create_event()
    attrs = Map.put(owned_fields(), field, nil)

    error =
      assert_raise Ecto.ConstraintError, fn ->
        insert_run!(event.id, "in_progress", attrs)
      end

    assert error.constraint == "sync_logs_active_ownership_fields_check"
  end

  defp owned_fields do
    now = DateTime.utc_now()

    %{
      sync_run_id: Ecto.UUID.generate(),
      owner_token: Ecto.UUID.generate(),
      heartbeat_at: now,
      lease_expires_at: DateTime.add(now, 180, :second)
    }
  end

  defp insert_run!(event_id, status, ownership) do
    %SyncLog{
      event_id: event_id,
      status: status,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      attendees_synced: 0,
      pages_processed: 0
    }
    |> struct(ownership)
    |> Repo.insert!()
  end
end
