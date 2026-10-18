defmodule FastCheck.Sales.DashboardAccessTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Sales.DashboardAccess

  @dashboard_username "admin"
  @granted_by "dashboard-operator"

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: @dashboard_username,
      password: "test-password",
      allowed_event_ids: [12, 14]
    })

    on_exit(fn -> restore_dashboard_auth(previous_auth) end)
    :ok
  end

  test "constructs an admin actor with configured Event IDs and no durable grants" do
    assert {:ok,
            %{
              actor_type: :admin,
              username: @dashboard_username,
              user_id: @dashboard_username,
              allowed_event_ids: [12, 14]
            }} = DashboardAccess.actor_for_identity(@dashboard_username)
  end

  test "revalidates a current dashboard identity without querying the database" do
    {result, queries} =
      capture_repo_queries(fn -> DashboardAccess.revalidate_identity(@dashboard_username) end)

    assert result == {:ok, @dashboard_username}
    assert queries == []
  end

  test "revalidation rejects an identity that does not match current configuration" do
    assert DashboardAccess.revalidate_identity("another-admin") == {:error, :unauthorized}
  end

  test "revalidation rejects a non-admin actor shape" do
    operator = %{actor_type: :operator, username: @dashboard_username}

    assert DashboardAccess.revalidate_identity(operator) == {:error, :unauthorized}
  end

  test "adds an active durable grant to actor allowed Event IDs" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_active_grant!(event, @dashboard_username)

    assert {:ok, %{allowed_event_ids: [event_id]}} =
             DashboardAccess.actor_for_identity(@dashboard_username)

    assert event_id == event.id
  end

  test "deduplicates and sorts configured and active durable Event IDs" do
    first_event = create_event()
    second_event = create_event()
    third_event = create_event()

    configure_allowed_event_ids([second_event.id, first_event.id, first_event.id])
    insert_active_grant!(first_event, @dashboard_username)
    insert_active_grant!(third_event, @dashboard_username)

    assert {:ok, %{allowed_event_ids: [first_id, second_id, third_id]}} =
             DashboardAccess.actor_for_identity(@dashboard_username)

    assert [first_id, second_id, third_id] ==
             [first_event.id, second_event.id, third_event.id]
  end

  test "returns current effective Event IDs from the public allowed IDs boundary" do
    first_event = create_event()
    second_event = create_event()
    third_event = create_event()
    revoked_event = create_event()

    configure_allowed_event_ids([third_event.id, first_event.id, first_event.id])
    insert_active_grant!(first_event, @dashboard_username)
    insert_active_grant!(second_event, @dashboard_username)
    insert_revoked_grant!(revoked_event, @dashboard_username)

    actor = %{
      actor_type: :admin,
      username: @dashboard_username,
      user_id: @dashboard_username,
      allowed_event_ids: [revoked_event.id, -1]
    }

    assert DashboardAccess.allowed_event_ids(actor) == [
             first_event.id,
             second_event.id,
             third_event.id
           ]
  end

  test "excludes a revoked durable grant from actor allowed Event IDs" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_revoked_grant!(event, @dashboard_username)

    assert {:ok, %{allowed_event_ids: []}} =
             DashboardAccess.actor_for_identity(@dashboard_username)
  end

  test "authorizes an active durable grant in an exact Event check" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_active_grant!(event, @dashboard_username)
    actor = admin_actor(@dashboard_username)

    assert DashboardAccess.event_granted?(actor, event.id)
  end

  test "denies a revoked-only durable grant in an exact Event check" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_revoked_grant!(event, @dashboard_username)
    actor = admin_actor(@dashboard_username)

    refute DashboardAccess.event_granted?(actor, event.id)
  end

  test "keeps configured authority when the durable grant history is revoked" do
    event = create_event()
    configure_allowed_event_ids([event.id])
    insert_revoked_grant!(event, @dashboard_username)
    actor = admin_actor(@dashboard_username)

    assert DashboardAccess.event_granted?(actor, event.id)
  end

  test "does not let another identity use its active durable grant" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_active_grant!(event, "another-dashboard")

    assert {:error, :unauthorized} = DashboardAccess.actor_for_identity("another-dashboard")

    actor = admin_actor("another-dashboard")
    refute DashboardAccess.event_granted?(actor, event.id)
  end

  test "ignores forged actor allowed Event IDs" do
    event = create_event()
    configure_allowed_event_ids([])
    actor = Map.put(admin_actor(@dashboard_username), :allowed_event_ids, [event.id])

    assert DashboardAccess.allowed_event_ids(actor) == []
    refute DashboardAccess.event_granted?(actor, event.id)
  end

  test "revalidates the current dashboard identity after actor construction" do
    event = create_event()
    configure_allowed_event_ids([])
    insert_active_grant!(event, @dashboard_username)

    assert {:ok, actor} = DashboardAccess.actor_for_identity(@dashboard_username)
    assert actor.allowed_event_ids == [event.id]

    configure_auth(%{username: "changed-admin"})

    assert DashboardAccess.allowed_event_ids(actor) == []
    refute DashboardAccess.event_granted?(actor, event.id)
  end

  test "rejects invalid and nonpositive Event IDs" do
    actor = admin_actor(@dashboard_username)

    for event_id <- [nil, 0, -1, "12", 1.0] do
      refute DashboardAccess.event_granted?(actor, event_id)
    end
  end

  test "rejects an identity that does not match dashboard configuration" do
    assert {:error, :unauthorized} = DashboardAccess.actor_for_identity("other")
  end

  test "does not turn a non-admin actor into dashboard authority by matching its username" do
    operator = %{actor_type: :operator, username: @dashboard_username}

    assert {:error, :unauthorized} = DashboardAccess.actor_for_identity(operator)
  end

  test "does not accept raw usernames as dashboard actors" do
    assert DashboardAccess.allowed_event_ids(@dashboard_username) == []
    refute DashboardAccess.event_granted?(@dashboard_username, 12)
  end

  defp admin_actor(username) do
    %{
      actor_type: :admin,
      username: username,
      user_id: username,
      allowed_event_ids: [99]
    }
  end

  defp configure_allowed_event_ids(event_ids) do
    configure_auth(%{allowed_event_ids: event_ids})
  end

  defp configure_auth(overrides) do
    auth = Application.fetch_env!(:fastcheck, :dashboard_auth)
    Application.put_env(:fastcheck, :dashboard_auth, Map.merge(auth, overrides))
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

    {1, _rows} = Repo.insert_all(DashboardEventGrant, [row])
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    ref = make_ref()
    handler_id = "dashboard-access-revalidate-#{System.unique_integer([:positive])}"
    parent = self()
    event_name = (Repo.config()[:telemetry_prefix] || [:fastcheck, :repo]) ++ [:query]

    :telemetry.attach(
      handler_id,
      event_name,
      fn _event, _measurements, metadata, _config ->
        send(parent, {:repo_query, ref, metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_repo_queries(ref, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(ref, queries) do
    receive do
      {:repo_query, ^ref, query} -> drain_repo_queries(ref, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp restore_dashboard_auth(nil), do: Application.delete_env(:fastcheck, :dashboard_auth)

  defp restore_dashboard_auth(auth),
    do: Application.put_env(:fastcheck, :dashboard_auth, auth)
end
