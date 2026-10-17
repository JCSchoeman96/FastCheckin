defmodule FastCheck.Repo.Migrations.CreateDashboardEventGrants do
  use Ecto.Migration

  def change do
    create table(:dashboard_event_grants) do
      add(:dashboard_identity, :string, null: false)
      add(:event_id, references(:events, on_delete: :restrict), null: false)
      add(:state, :string, null: false)
      add(:granted_at, :utc_datetime, null: false)
      add(:revoked_at, :utc_datetime)
      add(:granted_by, :string, null: false)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime)
    end

    create(
      constraint(:dashboard_event_grants, :dashboard_event_grants_state_valid,
        check: "state IN ('active', 'revoked')"
      )
    )

    create(
      constraint(:dashboard_event_grants, :dashboard_event_grants_state_revoked_at_consistent,
        check:
          "state NOT IN ('active', 'revoked') OR " <>
            "(state = 'active' AND revoked_at IS NULL) OR " <>
            "(state = 'revoked' AND revoked_at IS NOT NULL)"
      )
    )

    create(
      constraint(
        :dashboard_event_grants,
        :dashboard_event_grants_dashboard_identity_nonblank,
        check: "btrim(dashboard_identity) <> ''"
      )
    )

    create(
      constraint(:dashboard_event_grants, :dashboard_event_grants_granted_by_nonblank,
        check: "btrim(granted_by) <> ''"
      )
    )

    create(
      constraint(:dashboard_event_grants, :dashboard_event_grants_lock_version_positive,
        check: "lock_version > 0"
      )
    )

    create(
      index(:dashboard_event_grants, [:dashboard_identity, :state, :event_id],
        name: :dashboard_event_grants_identity_state_event_idx
      )
    )

    create(
      unique_index(:dashboard_event_grants, [:dashboard_identity, :event_id],
        name: :dashboard_event_grants_active_identity_event_uidx,
        where: "state = 'active'"
      )
    )

    create(
      index(:dashboard_event_grants, [:event_id], name: :dashboard_event_grants_event_id_idx)
    )
  end
end
