defmodule FastCheckWeb.SyncAuthorityGuardTest do
  use FastCheck.DataCase, async: false
  import Ecto.Query

  import FastCheck.Fixtures

  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheckWeb.SyncAuthorityGuard

  setup do
    previous = Application.get_env(:fastcheck, :dashboard_auth, %{})

    on_exit(fn -> Application.put_env(:fastcheck, :dashboard_auth, previous) end)
    :ok
  end

  test "dashboard guard reloads identity and grant on every check" do
    event = create_event()

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "admin",
      allowed_event_ids: [event.id]
    })

    guard = SyncAuthorityGuard.dashboard("admin")

    assert :ok = guard.(event.id)

    Application.put_env(:fastcheck, :dashboard_auth, %{username: "admin", allowed_event_ids: []})
    assert {:error, :authority_revoked} = guard.(event.id)

    Application.put_env(:fastcheck, :dashboard_auth, %{
      username: "different",
      allowed_event_ids: [event.id]
    })

    assert {:error, :authority_revoked} = guard.(event.id)
  end

  test "scanner guard stays scoped to its event and rechecks event availability" do
    event = create_event()
    other_event = create_event()
    guard = SyncAuthorityGuard.scanner_portal(event.id)

    assert :ok = guard.(event.id)
    assert {:error, :authority_revoked} = guard.(other_event.id)

    Repo.update_all(from(row in Event, where: row.id == ^event.id), set: [status: "archived"])
    assert {:error, :authority_revoked} = guard.(event.id)
    Repo.delete!(Repo.get!(Event, event.id))
    assert {:error, :authority_revoked} = guard.(event.id)
  end
end
