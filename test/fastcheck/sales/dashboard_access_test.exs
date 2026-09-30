defmodule FastCheck.Sales.DashboardAccessTest do
  use ExUnit.Case, async: false

  alias FastCheck.Sales.DashboardAccess

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      password: "test-password",
      allowed_event_ids: [12, 14]
    })

    on_exit(fn -> restore_dashboard_auth(previous_auth) end)
    :ok
  end

  test "constructs an admin actor from the configured dashboard identity" do
    assert {:ok,
            %{
              actor_type: :admin,
              username: "admin",
              user_id: "admin",
              allowed_event_ids: [12, 14]
            }} = DashboardAccess.actor_for_identity("admin")
  end

  test "rejects an identity that does not match dashboard configuration" do
    assert {:error, :unauthorized} = DashboardAccess.actor_for_identity("other")
  end

  test "does not turn a non-admin actor into dashboard authority by matching its username" do
    operator = %{actor_type: :operator, username: "admin"}

    assert {:error, :unauthorized} = DashboardAccess.actor_for_identity(operator)
  end

  test "re-reads server grants instead of trusting actor-supplied event ids" do
    actor = %{
      actor_type: :admin,
      username: "admin",
      user_id: "admin",
      allowed_event_ids: [99]
    }

    assert [12, 14] = DashboardAccess.allowed_event_ids(actor)
    assert DashboardAccess.event_granted?(actor, 12)
    refute DashboardAccess.event_granted?(actor, 99)
  end

  defp restore_dashboard_auth(nil), do: Application.delete_env(:fastcheck, :dashboard_auth)

  defp restore_dashboard_auth(auth),
    do: Application.put_env(:fastcheck, :dashboard_auth, auth)
end
