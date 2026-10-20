defmodule FastCheck.Access.DashboardEventGrantTransitionsTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Access.DashboardEventGrants
  alias FastCheck.Events.Event
  alias FastCheck.Sales.DashboardAccess

  @dashboard_username "admin"
  @granted_by "dashboard-operator"

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @dashboard_username,
      password: "test-password",
      allowed_event_ids: [],
      event_creation_enabled: true
    })

    on_exit(fn -> restore_dashboard_auth(previous_auth) end)
    :ok
  end

  describe "revoke_active_for_verified_identity/2" do
    test "transitions an active grant to revoked and increments lock_version" do
      event = create_event()
      grant = insert_active_grant!(event, @dashboard_username)
      assert grant.lock_version == 1

      assert {:ok, :revoked, revoked} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert revoked.id == grant.id
      assert revoked.state == "revoked"
      assert revoked.revoked_at
      assert revoked.lock_version == 2
    end

    test "repeated revoke is stable and does not change revoked_at or lock_version" do
      event = create_event()
      grant = insert_active_grant!(event, @dashboard_username)

      assert {:ok, :revoked, first} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert {:ok, :already_revoked, second} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert second.id == first.id
      assert second.revoked_at == first.revoked_at
      assert second.lock_version == 2
      assert Repo.aggregate(from(g in DashboardEventGrant, where: g.id == ^grant.id), :count) == 1
    end

    test "returns not_found when no grant history exists" do
      event = create_event()

      assert DashboardEventGrants.revoke_active_for_verified_identity(
               @dashboard_username,
               event.id
             ) == {:error, :not_found}
    end

    test "supports revoke, regrant, and revoke again across multiple historical rows" do
      event = create_event()
      grant_a = insert_active_grant!(event, @dashboard_username)

      assert {:ok, :revoked, revoked_a} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert revoked_a.id == grant_a.id

      assert {:ok, grant_b} =
               DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event.id)

      refute grant_b.id == grant_a.id
      assert grant_b.state == "active"

      assert {:ok, :revoked, revoked_b} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert revoked_b.id == grant_b.id
      assert revoked_b.lock_version == 2

      grants = grants_for_event(event.id)
      assert Enum.count(grants, &(&1.state == "revoked")) == 2
      refute Enum.any?(grants, &(&1.state == "active"))

      revoked_a_after = Repo.get!(DashboardEventGrant, grant_a.id)
      assert revoked_a_after.state == "revoked"
      assert revoked_a_after.lock_version == 2

      revoked_b_after = Repo.get!(DashboardEventGrant, grant_b.id)
      revoked_at_b = revoked_b_after.revoked_at
      lock_b = revoked_b_after.lock_version

      assert {:ok, :already_revoked, already} =
               DashboardEventGrants.revoke_active_for_verified_identity(
                 @dashboard_username,
                 event.id
               )

      assert already.id == grant_b.id
      assert already.revoked_at == revoked_at_b
      assert already.lock_version == lock_b
      assert Repo.get!(DashboardEventGrant, grant_b.id).lock_version == lock_b
    end

    test "concurrent revoke performs one transition and converges on already_revoked" do
      {event_id, _grant_id} = committed_active_grant!(@dashboard_username)
      register_committed_event_cleanup!(event_id)

      results =
        concurrent_barrier_run(2, fn ->
          DashboardEventGrants.revoke_active_for_verified_identity(
            @dashboard_username,
            event_id
          )
        end)

      statuses = Enum.map(results, &elem(&1, 1))
      assert Enum.sort(statuses) == [:already_revoked, :revoked]

      assert [%DashboardEventGrant{state: "revoked", lock_version: 2}] =
               committed_grants_for_event(event_id)
    end
  end

  describe "regrant_for_verified_identity/2" do
    test "inserts a new active row after revoked history" do
      event = create_event()
      revoked = insert_revoked_grant!(event, @dashboard_username)

      assert {:ok, active} =
               DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event.id)

      assert active.id != revoked.id
      assert active.state == "active"
      assert active.lock_version == 1
      assert active.revoked_at == nil
      assert active.granted_by == @dashboard_username

      assert [%{id: revoked_id, state: "revoked"}, %{id: active_id, state: "active"}] =
               grants_for_event(event.id)
               |> Enum.sort_by(& &1.id)

      assert revoked_id == revoked.id
      assert active_id == active.id
    end

    test "returns the existing active grant without inserting another row" do
      event = create_event()
      grant = insert_active_grant!(event, @dashboard_username)
      count_before = Repo.aggregate(DashboardEventGrant, :count)

      assert {:ok, same} =
               DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event.id)

      assert same.id == grant.id
      assert Repo.aggregate(DashboardEventGrant, :count) == count_before
    end

    test "denies regrant when no grant history exists" do
      event = create_event()

      assert DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event.id) ==
               {:error, :not_found}

      assert grants_for_event(event.id) == []
    end

    test "concurrent regrant converges on one active grant id" do
      {event_id, _revoked_id} = committed_revoked_history!(@dashboard_username)
      register_committed_event_cleanup!(event_id)

      assert [{:ok, first}, {:ok, second}] =
               concurrent_barrier_run(2, fn ->
                 DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event_id)
               end)

      assert first.id == second.id
      assert first.state == "active"

      grants = committed_grants_for_event(event_id)
      assert length(grants) == 2
      assert Enum.count(grants, &(&1.state == "revoked")) == 1
      assert Enum.count(grants, &(&1.state == "active")) == 1
      assert Enum.find(grants, &(&1.state == "active")).id == first.id
    end
  end

  describe "revoke vs regrant concurrency" do
    test "independent connections never crash and preserve terminal history" do
      {event_id, _grant_id} = committed_active_grant!(@dashboard_username)
      register_committed_event_cleanup!(event_id)

      results =
        concurrent_barrier_run(
          [{:revoke, :revoke}, {:regrant, :regrant}],
          fn
            {:revoke, _} ->
              DashboardEventGrants.revoke_active_for_verified_identity(
                @dashboard_username,
                event_id
              )

            {:regrant, _} ->
              DashboardEventGrants.regrant_for_verified_identity(@dashboard_username, event_id)
          end
        )

      revoke_results =
        Enum.filter(results, fn
          {:ok, :revoked, _} -> true
          {:ok, :already_revoked, _} -> true
          _ -> false
        end)

      regrant_results = Enum.filter(results, &match?({:ok, %DashboardEventGrant{}}, &1))

      assert revoke_results != []
      assert regrant_results != []
      refute Enum.any?(results, &match?({:error, :not_found}, &1))

      grants = committed_grants_for_event(event_id)
      active_grants = Enum.filter(grants, &(&1.state == "active"))
      assert length(active_grants) <= 1

      revoked_grants = Enum.filter(grants, &(&1.state == "revoked"))
      assert Enum.all?(revoked_grants, &(&1.revoked_at != nil))
      assert Enum.all?(revoked_grants, &(&1.state == "revoked"))
    end
  end

  describe "DashboardAccess.revoke_event_grant/2" do
    test "reports effective_access granted when configuration still allows the Event" do
      event = create_event()
      insert_active_grant!(event, @dashboard_username)
      configure_allowed_event_ids([event.id])

      assert {:ok, %{status: :revoked, effective_access: :granted}} =
               DashboardAccess.revoke_event_grant(@dashboard_username, event.id)

      assert DashboardAccess.event_granted_for_identity?(@dashboard_username, event.id)
    end

    test "reports effective_access denied for a DB-only grant" do
      event = create_event()
      insert_active_grant!(event, @dashboard_username)

      assert {:ok, %{status: :revoked, effective_access: :denied}} =
               DashboardAccess.revoke_event_grant(@dashboard_username, event.id)

      refute DashboardAccess.event_granted_for_identity?(@dashboard_username, event.id)
    end

    test "rejects forged identities without mutating grants" do
      event = create_event()
      grant = insert_active_grant!(event, @dashboard_username)

      assert DashboardAccess.revoke_event_grant("forged-admin", event.id) ==
               {:error, :unauthorized}

      assert Repo.get!(DashboardEventGrant, grant.id).state == "active"
    end
  end

  describe "DashboardAccess.regrant_event_grant/2" do
    test "regrants through the public boundary after revoked history" do
      event = create_event()
      insert_revoked_grant!(event, @dashboard_username)

      assert {:ok, grant} = DashboardAccess.regrant_event_grant(@dashboard_username, event.id)
      assert grant.state == "active"
      assert DashboardAccess.event_granted_for_identity?(@dashboard_username, event.id)
    end

    test "blocks arbitrary Event regrant with no history" do
      event = create_event()

      assert DashboardAccess.regrant_event_grant(@dashboard_username, event.id) ==
               {:error, :not_found}

      assert grants_for_event(event.id) == []
    end
  end

  defp concurrent_barrier_run(competitors, fun)
       when is_integer(competitors) and is_function(fun, 0) do
    concurrent_barrier_run(Enum.to_list(1..competitors), fn _n -> fun.() end)
  end

  defp concurrent_barrier_run(competitors, fun) when is_function(fun, 1) do
    parent = self()

    tasks =
      Enum.map(competitors, fn label ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:barrier_waiting, self()})

            receive do
              :continue -> :ok
            end

            fun.(label)
          end)
        end)
      end)

    barrier_pids =
      for _ <- competitors do
        assert_receive {:barrier_waiting, pid}, 5_000
        pid
      end

    assert length(Enum.uniq(barrier_pids)) == length(competitors)
    Enum.each(barrier_pids, &send(&1, :continue))

    Task.await_many(tasks, 10_000)
  end

  defp committed_active_grant!(identity) do
    Sandbox.unboxed_run(Repo, fn ->
      event = create_event()
      grant = insert_active_grant!(event, identity)
      {event.id, grant.id}
    end)
  end

  defp committed_revoked_history!(identity) do
    Sandbox.unboxed_run(Repo, fn ->
      event = create_event()
      revoked = insert_revoked_grant!(event, identity)
      {event.id, revoked.id}
    end)
  end

  defp committed_grants_for_event(event_id) do
    Sandbox.unboxed_run(Repo, fn -> grants_for_event(event_id) end)
  end

  defp register_committed_event_cleanup!(event_id) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from grant in DashboardEventGrant, where: grant.event_id == ^event_id)
        Repo.delete_all(from event in Event, where: event.id == ^event_id)
      end)
    end)
  end

  defp configure_allowed_event_ids(event_ids) do
    auth = Application.fetch_env!(:fastcheck, :dashboard_auth)
    Application.put_env(:fastcheck, :dashboard_auth, Map.put(auth, :allowed_event_ids, event_ids))
  end

  defp insert_active_grant!(event, identity) do
    %DashboardEventGrant{}
    |> DashboardEventGrant.changeset(%{
      dashboard_identity: identity,
      event_id: event.id,
      granted_at: timestamp(),
      granted_by: @granted_by
    })
    |> Repo.insert!()
  end

  defp insert_revoked_grant!(event, identity) do
    now = timestamp()

    row = %{
      dashboard_identity: identity,
      event_id: event.id,
      state: "revoked",
      granted_at: now,
      revoked_at: now,
      granted_by: @granted_by,
      lock_version: 1,
      inserted_at: now,
      updated_at: now
    }

    {1, [%{id: id}]} = Repo.insert_all(DashboardEventGrant, [row], returning: [:id])
    Repo.get!(DashboardEventGrant, id)
  end

  defp grants_for_event(event_id) do
    Repo.all(
      from grant in DashboardEventGrant,
        where: grant.event_id == ^event_id,
        order_by: [asc: grant.id]
    )
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp restore_dashboard_auth(nil), do: Application.delete_env(:fastcheck, :dashboard_auth)

  defp restore_dashboard_auth(auth),
    do: Application.put_env(:fastcheck, :dashboard_auth, auth)
end
