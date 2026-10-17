defmodule FastCheck.Access.DashboardEventGrantTest do
  use FastCheck.DataCase, async: false

  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Events.Event

  @dashboard_identity "dashboard-owner"
  @granted_by "dashboard-operator"

  test "active grant persists with no revoked timestamp" do
    event = create_event()

    grant = insert_grant!(event)

    assert grant.state == "active"
    assert grant.revoked_at == nil
    assert Repo.get!(DashboardEventGrant, grant.id).revoked_at == nil
  end

  test "Postgres rejects an unsupported state" do
    event = create_event()

    assert_database_constraint(event, %{state: "pending"},
      name: "dashboard_event_grants_state_valid"
    )
  end

  test "Postgres rejects an active grant with a revoked timestamp" do
    event = create_event()

    assert_database_constraint(event, %{revoked_at: timestamp()},
      name: "dashboard_event_grants_state_revoked_at_consistent"
    )
  end

  test "Postgres rejects a revoked grant without a revoked timestamp" do
    event = create_event()

    assert_database_constraint(event, %{state: "revoked"},
      name: "dashboard_event_grants_state_revoked_at_consistent"
    )
  end

  test "blank dashboard identity is rejected by the changeset and Postgres" do
    event = create_event()
    attrs = grant_attrs(event, %{dashboard_identity: "  "})

    changeset = DashboardEventGrant.changeset(%DashboardEventGrant{}, attrs)
    assert errors_on(changeset).dashboard_identity

    assert_database_constraint(event, %{dashboard_identity: "  "},
      name: "dashboard_event_grants_dashboard_identity_nonblank"
    )
  end

  test "blank grantor is rejected by the changeset and Postgres" do
    event = create_event()
    attrs = grant_attrs(event, %{granted_by: "  "})

    changeset = DashboardEventGrant.changeset(%DashboardEventGrant{}, attrs)
    assert errors_on(changeset).granted_by

    assert_database_constraint(event, %{granted_by: "  "},
      name: "dashboard_event_grants_granted_by_nonblank"
    )
  end

  test "a nonpositive lock version is rejected by the changeset and Postgres" do
    event = create_event()
    attrs = grant_attrs(event, %{lock_version: 0})

    changeset = DashboardEventGrant.changeset(%DashboardEventGrant{}, attrs)
    assert errors_on(changeset).lock_version

    assert_database_constraint(event, %{lock_version: 0},
      name: "dashboard_event_grants_lock_version_positive"
    )
  end

  test "Postgres rejects a duplicate active identity and event grant" do
    event = create_event()
    insert_grant!(event)

    assert_database_constraint(event, %{},
      name: "dashboard_event_grants_active_identity_event_uidx"
    )
  end

  test "a revoked historical grant permits a fresh active grant" do
    event = create_event()
    revoked_at = timestamp()

    revoked = insert_grant!(event, %{state: "revoked", revoked_at: revoked_at})
    active = insert_grant!(event)

    assert revoked.state == "revoked"
    assert revoked.revoked_at
    assert active.state == "active"
    assert active.revoked_at == nil
    refute active.id == revoked.id
  end

  test "a grant row restricts Event deletion" do
    event = create_event()
    insert_grant!(event)

    assert_raise Postgrex.Error, ~r/dashboard_event_grants_event_id_fkey/, fn ->
      Repo.query!("DELETE FROM events WHERE id = $1", [event.id])
    end
  end

  test "Event preloads its dashboard grant history" do
    event = create_event()
    grant = insert_grant!(event)

    loaded_event = Repo.preload(event, :dashboard_event_grants)

    assert [%DashboardEventGrant{id: grant_id}] = loaded_event.dashboard_event_grants
    assert grant_id == grant.id
    assert match?(%Event{id: id} when id == event.id, loaded_event)
  end

  defp insert_grant!(event, overrides \\ %{}) do
    event
    |> grant_attrs(overrides)
    |> then(&DashboardEventGrant.changeset(%DashboardEventGrant{}, &1))
    |> Repo.insert!()
  end

  defp grant_attrs(event, overrides) do
    Map.merge(
      %{
        dashboard_identity: @dashboard_identity,
        event_id: event.id,
        state: "active",
        granted_at: timestamp(),
        revoked_at: nil,
        granted_by: @granted_by,
        lock_version: 1
      },
      overrides
    )
  end

  defp assert_database_constraint(event, overrides, name: constraint_name) do
    attrs = grant_attrs(event, overrides)
    now = timestamp()

    row =
      attrs
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)

    assert_raise Postgrex.Error, ~r/#{constraint_name}/, fn ->
      Repo.insert_all(DashboardEventGrant, [row])
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end
end
