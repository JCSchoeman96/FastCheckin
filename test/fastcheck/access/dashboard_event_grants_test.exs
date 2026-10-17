defmodule FastCheck.Access.DashboardEventGrantsTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Access.DashboardEventGrants

  @dashboard_identity "DashboardOwner"
  @granted_by "dashboard-operator"

  test "returns active Event IDs in ascending order for the exact identity" do
    first_event = create_event()
    revoked_event = create_event()
    last_event = create_event()
    other_identity_event = create_event()

    insert_grant!(last_event, @dashboard_identity)
    insert_grant!(first_event, @dashboard_identity)
    insert_revoked_grant!(revoked_event, @dashboard_identity)
    insert_grant!(other_identity_event, "another-dashboard")

    assert DashboardEventGrants.active_event_ids_for_identity(@dashboard_identity) == [
             first_event.id,
             last_event.id
           ]
  end

  test "does not match an identity with different casing" do
    event = create_event()
    insert_grant!(event, "DashboardOwner")

    assert DashboardEventGrants.active_event_ids_for_identity("DashboardOwner") == [event.id]
    assert DashboardEventGrants.active_event_ids_for_identity("dashboardowner") == []
  end

  test "returns no Event IDs for a blank identity" do
    assert DashboardEventGrants.active_event_ids_for_identity("") == []
    assert DashboardEventGrants.active_event_ids_for_identity(" \t\n ") == []
  end

  test "returns no Event IDs for a malformed or non-binary identity" do
    for invalid_identity <- [nil, 42, :dashboard_owner, %{identity: @dashboard_identity}, <<255>>] do
      assert DashboardEventGrants.active_event_ids_for_identity(invalid_identity) == []
    end
  end

  test "reports an active grant for the exact identity and Event" do
    event = create_event()
    insert_grant!(event, @dashboard_identity)

    assert DashboardEventGrants.active_grant_exists?(@dashboard_identity, event.id)
  end

  test "reports no grant for a revoked-only identity and Event pair" do
    event = create_event()
    insert_revoked_grant!(event, @dashboard_identity)

    refute DashboardEventGrants.active_grant_exists?(@dashboard_identity, event.id)
  end

  test "does not report another identity's active grant" do
    event = create_event()
    insert_grant!(event, "another-dashboard")

    refute DashboardEventGrants.active_grant_exists?(@dashboard_identity, event.id)
  end

  test "does not report an active grant for another Event" do
    granted_event = create_event()
    other_event = create_event()
    insert_grant!(granted_event, @dashboard_identity)

    refute DashboardEventGrants.active_grant_exists?(@dashboard_identity, other_event.id)
  end

  test "reports no active grant for invalid or nonpositive Event IDs" do
    for invalid_event_id <- [nil, 0, -1, "1", 1.0] do
      refute DashboardEventGrants.active_grant_exists?(@dashboard_identity, invalid_event_id)
    end
  end

  test "reports no active grant for an invalid identity" do
    event = create_event()
    insert_grant!(event, @dashboard_identity)

    for invalid_identity <- [
          "",
          "  ",
          nil,
          42,
          :dashboard_owner,
          %{identity: @dashboard_identity},
          <<255>>
        ] do
      refute DashboardEventGrants.active_grant_exists?(invalid_identity, event.id)
    end
  end

  test "a newer active grant is authoritative over revoked history" do
    event = create_event()
    insert_revoked_grant!(event, @dashboard_identity)
    insert_grant!(event, @dashboard_identity)

    assert DashboardEventGrants.active_grant_exists?(@dashboard_identity, event.id)
  end

  defp insert_grant!(event, identity) do
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
end
