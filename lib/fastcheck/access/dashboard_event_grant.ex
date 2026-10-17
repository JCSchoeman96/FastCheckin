defmodule FastCheck.Access.DashboardEventGrant do
  @moduledoc """
  Persists dashboard identity grants and their terminal revocation history for Events.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Events.Event

  @states ["active", "revoked"]

  schema "dashboard_event_grants" do
    field :dashboard_identity, :string
    belongs_to :event, Event
    field :state, :string
    field :granted_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :granted_by, :string
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc "Builds a changeset for persisting a dashboard Event grant row."
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [
      :dashboard_identity,
      :event_id,
      :state,
      :granted_at,
      :revoked_at,
      :granted_by,
      :lock_version
    ])
    |> validate_required([
      :dashboard_identity,
      :event_id,
      :state,
      :granted_at,
      :granted_by,
      :lock_version
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:lock_version, greater_than: 0)
    |> check_constraint(:state, name: "dashboard_event_grants_state_valid")
    |> check_constraint(:state,
      name: "dashboard_event_grants_state_revoked_at_consistent"
    )
    |> check_constraint(:dashboard_identity,
      name: "dashboard_event_grants_dashboard_identity_nonblank"
    )
    |> check_constraint(:granted_by, name: "dashboard_event_grants_granted_by_nonblank")
    |> check_constraint(:lock_version,
      name: "dashboard_event_grants_lock_version_positive"
    )
    |> unique_constraint(:event_id,
      name: "dashboard_event_grants_active_identity_event_uidx"
    )
    |> foreign_key_constraint(:event_id, name: "dashboard_event_grants_event_id_fkey")
  end
end
