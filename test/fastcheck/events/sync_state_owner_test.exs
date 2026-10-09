defmodule FastCheck.Events.SyncStateOwnerTest do
  use ExUnit.Case, async: false

  alias FastCheck.Events.SyncState

  setup do
    event_id = System.unique_integer([:positive])
    sync_run_id = Ecto.UUID.generate()
    owner_token = Ecto.UUID.generate()

    on_exit(fn -> SyncState.clear_state(event_id) end)

    %{event_id: event_id, sync_run_id: sync_run_id, owner_token: owner_token}
  end

  test "owned initialization stores owner and initial progress", context do
    sync_log_id = System.unique_integer([:positive])

    assert :ok =
             SyncState.init_sync(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               sync_log_id
             )

    assert {:ok, state} =
             SyncState.get_state(
               context.event_id,
               context.sync_run_id,
               context.owner_token
             )

    assert state == %{
             sync_run_id: context.sync_run_id,
             owner_token: context.owner_token,
             status: :running,
             current_page: 0,
             total_pages: nil,
             attendees_processed: 0,
             sync_log_id: sync_log_id
           }
  end

  test "matching owner can update progress and control lifecycle", context do
    assert :ok = init_owner(context)

    assert :ok =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               3,
               8,
               42
             )

    assert {:ok, %{current_page: 3, total_pages: 8, attendees_processed: 42}} =
             SyncState.get_state(
               context.event_id,
               context.sync_run_id,
               context.owner_token
             )

    assert true =
             SyncState.should_continue?(
               context.event_id,
               context.sync_run_id,
               context.owner_token
             )

    assert 3 =
             SyncState.get_resume_page(
               context.event_id,
               context.sync_run_id,
               context.owner_token
             )

    assert :ok = owner_operation(context, :pause_sync)
    assert {:ok, %{status: :paused}} = owner_state(context)

    assert :ok = owner_operation(context, :resume_sync)
    assert {:ok, %{status: :running}} = owner_state(context)

    assert :ok = owner_operation(context, :cancel_sync)
    assert {:ok, %{status: :cancelled}} = owner_state(context)

    assert :ok = owner_operation(context, :clear_state)
    assert {:error, :not_found} = owner_state(context)
  end

  test "wrong run id is stale and cannot update progress", context do
    assert :ok = init_owner(context)
    wrong_run_id = Ecto.UUID.generate()
    before = owner_state(context)

    assert {:error, :stale_owner} =
             SyncState.update_progress(
               context.event_id,
               wrong_run_id,
               context.owner_token,
               9,
               9,
               99
             )

    assert {:error, :stale_owner} =
             SyncState.get_state(context.event_id, wrong_run_id, context.owner_token)

    assert owner_state(context) == before
  end

  test "wrong owner token is stale and cannot update progress", context do
    assert :ok = init_owner(context)
    wrong_owner_token = Ecto.UUID.generate()
    before = owner_state(context)

    assert {:error, :stale_owner} =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               wrong_owner_token,
               9,
               9,
               99
             )

    assert {:error, :stale_owner} =
             SyncState.get_state(context.event_id, context.sync_run_id, wrong_owner_token)

    assert owner_state(context) == before
  end

  test "a new owner replaces the old hot mirror and fences every old operation", context do
    assert :ok = init_owner(context)

    assert :ok =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               4,
               8,
               40
             )

    new_owner = %{
      sync_run_id: Ecto.UUID.generate(),
      owner_token: Ecto.UUID.generate()
    }

    assert :ok =
             SyncState.init_sync(
               context.event_id,
               new_owner.sync_run_id,
               new_owner.owner_token,
               nil
             )

    new_owner_state =
      SyncState.get_state(context.event_id, new_owner.sync_run_id, new_owner.owner_token)

    assert {:error, :stale_owner} = owner_state(context)

    assert {:error, :stale_owner} =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               9,
               9,
               99
             )

    assert {:error, :stale_owner} = owner_operation(context, :pause_sync)
    assert {:error, :stale_owner} = owner_operation(context, :resume_sync)
    assert {:error, :stale_owner} = owner_operation(context, :cancel_sync)
    assert {:error, :stale_owner} = owner_operation(context, :clear_state)

    assert SyncState.should_continue?(context.event_id, context.sync_run_id, context.owner_token) ==
             false

    assert SyncState.get_resume_page(context.event_id, context.sync_run_id, context.owner_token) ==
             0

    assert SyncState.get_state(context.event_id, new_owner.sync_run_id, new_owner.owner_token) ==
             new_owner_state
  end

  test "legacy state is not treated as owner proof", context do
    assert :ok = SyncState.init_sync(context.event_id, 123)
    legacy_state = SyncState.get_state(context.event_id)

    assert {:error, :stale_owner} = owner_state(context)

    assert {:error, :stale_owner} =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               2,
               4,
               20
             )

    assert SyncState.get_state(context.event_id) == legacy_state
  end

  test "missing event returns not found for owner access and mutations", context do
    assert {:error, :not_found} = owner_state(context)

    assert {:error, :not_found} =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               1,
               1,
               1
             )

    assert {:error, :not_found} = owner_operation(context, :pause_sync)
    assert {:error, :not_found} = owner_operation(context, :resume_sync)
    assert {:error, :not_found} = owner_operation(context, :cancel_sync)
    assert {:error, :not_found} = owner_operation(context, :clear_state)
  end

  test "stale owner convenience reads hide another owner's state", context do
    assert :ok = init_owner(context)

    assert :ok =
             SyncState.update_progress(
               context.event_id,
               context.sync_run_id,
               context.owner_token,
               7,
               9,
               70
             )

    new_sync_run_id = Ecto.UUID.generate()
    new_owner_token = Ecto.UUID.generate()
    assert :ok = SyncState.init_sync(context.event_id, new_sync_run_id, new_owner_token, nil)

    refute SyncState.should_continue?(
             context.event_id,
             context.sync_run_id,
             context.owner_token
           )

    assert 0 =
             SyncState.get_resume_page(
               context.event_id,
               context.sync_run_id,
               context.owner_token
             )
  end

  test "legacy API behavior remains available", context do
    sync_log_id = System.unique_integer([:positive])

    assert :ok = SyncState.init_sync(context.event_id, sync_log_id)

    assert %{status: :running, current_page: 0, sync_log_id: ^sync_log_id} =
             SyncState.get_state(context.event_id)

    assert :ok = SyncState.update_progress(context.event_id, 2, 5, 20)

    assert %{current_page: 2, total_pages: 5, attendees_processed: 20} =
             SyncState.get_state(context.event_id)

    assert :ok = SyncState.pause_sync(context.event_id)
    assert %{status: :paused} = SyncState.get_state(context.event_id)
    refute SyncState.should_continue?(context.event_id)

    assert :ok = SyncState.resume_sync(context.event_id)
    assert true = SyncState.should_continue?(context.event_id)

    assert :ok = SyncState.cancel_sync(context.event_id)
    assert %{status: :cancelled} = SyncState.get_state(context.event_id)
    assert 2 = SyncState.get_resume_page(context.event_id)

    assert :ok = SyncState.clear_state(context.event_id)
    assert is_nil(SyncState.get_state(context.event_id))
  end

  defp init_owner(context) do
    SyncState.init_sync(
      context.event_id,
      context.sync_run_id,
      context.owner_token,
      nil
    )
  end

  defp owner_state(context) do
    SyncState.get_state(
      context.event_id,
      context.sync_run_id,
      context.owner_token
    )
  end

  defp owner_operation(context, operation) do
    apply(SyncState, operation, [context.event_id, context.sync_run_id, context.owner_token])
  end
end
