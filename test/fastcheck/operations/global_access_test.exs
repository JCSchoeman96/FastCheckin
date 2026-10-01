defmodule FastCheck.Operations.GlobalAccessTest do
  use ExUnit.Case, async: false

  alias FastCheck.Operations.GlobalAccess
  alias FastCheck.RuntimeConfiguration

  setup do
    previous_access = Application.get_env(:fastcheck, :operations_global_access)
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)

    Application.put_env(:fastcheck, :dashboard_auth, %{username: "admin", allowed_event_ids: []})
    Application.delete_env(:fastcheck, :operations_global_access)

    on_exit(fn ->
      restore(:operations_global_access, previous_access)
      restore(:dashboard_auth, previous_auth)
    end)

    :ok
  end

  test "defaults to the configured dashboard username" do
    assert GlobalAccess.allowed_usernames() == ["admin"]
    assert GlobalAccess.authorized?("admin")
    refute GlobalAccess.authorized?("other")
  end

  test "explicit allowlist replaces the bootstrap username" do
    Application.put_env(:fastcheck, :operations_global_access, allowed_usernames: ["ops", "ops"])

    assert GlobalAccess.allowed_usernames() == ["ops"]
    assert GlobalAccess.authorized?("ops")
    refute GlobalAccess.authorized?("admin")
  end

  test "event grants and client actor maps cannot grant global access" do
    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      allowed_event_ids: [123]
    })

    assert GlobalAccess.authorized?("admin")
    refute GlobalAccess.authorized?(%{username: "admin", allowed_event_ids: [123]})
    refute GlobalAccess.authorized?(%{"username" => "admin", "allowed_event_ids" => [123]})
    refute GlobalAccess.authorized?("event-grantee")
  end

  test "runtime parser trims and rejects wildcard configuration" do
    assert {:ok, ["admin", "ops"]} =
             RuntimeConfiguration.operations_global_monitoring_usernames(
               " admin, ops,admin ",
               "bootstrap"
             )

    assert {:ok, ["bootstrap"]} =
             RuntimeConfiguration.operations_global_monitoring_usernames("  ", "bootstrap")

    assert {:error, :wildcard_not_allowed} =
             RuntimeConfiguration.operations_global_monitoring_usernames("admin,*", "bootstrap")
  end

  defp restore(key, nil), do: Application.delete_env(:fastcheck, key)
  defp restore(key, value), do: Application.put_env(:fastcheck, key, value)
end
