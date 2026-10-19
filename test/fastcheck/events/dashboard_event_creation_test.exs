defmodule FastCheck.Events.DashboardEventCreationTest do
  use FastCheck.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Access.DashboardEventGrant
  alias FastCheck.Events
  alias FastCheck.Events.{Event, SyncLog}
  alias FastCheck.Sales.DashboardAccess
  alias Req.Response

  @dashboard_username "current-dashboard-admin"
  @tickera_essentials %{
    "event_name" => "Prepared Tickera Event",
    "event_date_time" => "2026-10-22T19:00:00Z",
    "event_location" => "Prepared Venue",
    "sold_tickets" => 80,
    "checked_tickets" => 3,
    "pass" => true
  }

  setup do
    previous_auth = Application.get_env(:fastcheck, :dashboard_auth)
    previous_request_fun = Application.get_env(:fastcheck, :tickera_request_fun)

    configure_dashboard_auth(%{
      username: @dashboard_username,
      password: "test-password",
      allowed_event_ids: [],
      event_creation_enabled: true
    })

    on_exit(fn ->
      restore_env(:dashboard_auth, previous_auth)
      restore_env(:tickera_request_fun, previous_request_fun)
    end)

    :ok
  end

  test "generates distinct UUID creation tokens" do
    first = Events.new_dashboard_creation_token()
    second = Events.new_dashboard_creation_token()

    assert {:ok, ^first} = Ecto.UUID.cast(first)
    assert {:ok, ^second} = Ecto.UUID.cast(second)
    refute first == second
  end

  test "rejects an identity that no longer matches configuration before Tickera or writes" do
    token = Ecto.UUID.generate()
    counts_before = database_counts()
    install_tickera_mock(@tickera_essentials)

    assert {:error, :unauthorized} =
             Events.create_event_for_dashboard("stale-dashboard-admin", token, create_attrs())

    refute_received {:tickera_request, _path}
    assert database_counts() == counts_before
    assert events_for_token(token) == []
  end

  test "rejects disabled dashboard Event creation before Tickera or writes" do
    token = Ecto.UUID.generate()
    counts_before = database_counts()
    configure_dashboard_auth(%{event_creation_enabled: false})
    install_tickera_mock(@tickera_essentials)

    assert {:error, :event_creation_disabled} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    refute_received {:tickera_request, _path}
    assert database_counts() == counts_before
    assert events_for_token(token) == []
  end

  test "rejects a malformed creation token before Tickera or writes" do
    counts_before = database_counts()
    install_tickera_mock(@tickera_essentials)

    assert {:error, :invalid_dashboard_creation_token} =
             Events.create_event_for_dashboard(
               @dashboard_username,
               "not-a-uuid",
               create_attrs()
             )

    refute_received {:tickera_request, _path}
    assert database_counts() == counts_before
  end

  test "creates one Event and its server-derived creator grant atomically" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    attrs =
      create_attrs()
      |> Map.merge(%{
        "dashboard_identity" => "forged-identity",
        "granted_by" => "forged-grantor",
        "event_id" => 9_999_999,
        "state" => "revoked"
      })

    assert {:ok, %Event{} = event} =
             Events.create_event_for_dashboard(@dashboard_username, token, attrs)

    assert_tickera_creation_requests()
    assert [stored_event] = events_for_token(token)
    assert stored_event.id == event.id
    assert stored_event.dashboard_creation_token == token

    assert [grant] = grants_for_event(event.id)
    assert grant.state == "active"
    assert grant.dashboard_identity == @dashboard_username
    assert grant.granted_by == @dashboard_username
    assert grant.event_id == event.id
    assert grant.granted_at

    actor = %{actor_type: :admin, username: @dashboard_username}
    assert DashboardAccess.event_granted?(actor, event.id)

    refute Repo.exists?(from log in SyncLog, where: log.event_id == ^event.id)
    refute event.whatsapp_sales_enabled
  end

  test "does not insert a creator grant when the Event insert fails" do
    token = Ecto.UUID.generate()
    constraint = "dashboard_event_insert_failure_for_test"
    counts_before = database_counts()
    install_tickera_mock(@tickera_essentials)

    Repo.query!(
      "ALTER TABLE events ADD CONSTRAINT #{constraint} CHECK (name <> 'Prepared Tickera Event') NOT VALID"
    )

    try do
      assert {:error, :database_error} =
               Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

      assert events_for_token(token) == []
      assert database_counts() == counts_before
    after
      Repo.query!("ALTER TABLE events DROP CONSTRAINT #{constraint}")
    end
  end

  test "rolls back the Event when the creator-grant insert fails and reuses the token" do
    token = Ecto.UUID.generate()
    constraint = "dashboard_event_grant_insert_failure_for_test"
    counts_before = database_counts()
    install_tickera_mock(@tickera_essentials)

    Repo.query!(
      "ALTER TABLE dashboard_event_grants ADD CONSTRAINT #{constraint} CHECK (false) NOT VALID"
    )

    try do
      assert {:error, :database_error} =
               Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

      assert events_for_token(token) == []
      assert database_counts() == counts_before
    after
      Repo.query!("ALTER TABLE dashboard_event_grants DROP CONSTRAINT #{constraint}")
    end

    assert {:ok, %Event{} = event} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert length(events_for_token(token)) == 1
    assert length(grants_for_event(event.id)) == 1
  end

  test "returns a committed Event on replay without repeating Tickera requests" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    assert {:ok, first} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()

    assert {:ok, replayed} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert replayed.id == first.id
    refute_received {:tickera_request, _path}
    assert length(events_for_token(token)) == 1
    assert length(grants_for_event(first.id)) == 1
  end

  test "returns the original Event when replay form values changed" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    assert {:ok, first} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()

    changed_attrs = %{
      "tickera_site_url" => "https://changed.example",
      "tickera_api_key_encrypted" => "changed-api-key",
      "mobile_access_code" => "changed-mobile-secret",
      "name" => "Changed Event Name",
      "location" => "Changed Location"
    }

    assert {:ok, replayed} =
             Events.create_event_for_dashboard(@dashboard_username, token, changed_attrs)

    assert replayed.id == first.id
    assert replayed.name == first.name
    assert replayed.location == first.location
    refute_received {:tickera_request, _path}
    assert [%Event{name: original_name, location: original_location}] = events_for_token(token)
    assert original_name == first.name
    assert original_location == first.location
  end

  test "denies replay when the current identity has no effective Event authority" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    assert {:ok, event} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()
    revoke_creator_grant!(event.id)

    assert {:error, :unauthorized} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    refute_received {:tickera_request, _path}
    assert length(events_for_token(token)) == 1
    assert [%DashboardEventGrant{state: "revoked"}] = grants_for_event(event.id)
  end

  test "denies committed-token replay when the creation flag is disabled" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    assert {:ok, event} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()
    configure_dashboard_auth(%{event_creation_enabled: false})

    assert {:error, :event_creation_disabled} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    refute_received {:tickera_request, _path}
    assert [stored_event] = events_for_token(token)
    assert stored_event.id == event.id
    assert length(grants_for_event(event.id)) == 1
  end

  test "keeps configured Event authority additive when the creator grant is revoked" do
    token = Ecto.UUID.generate()
    install_tickera_mock(@tickera_essentials)

    assert {:ok, event} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()
    configure_dashboard_auth(%{allowed_event_ids: [event.id]})
    revoke_creator_grant!(event.id)

    assert {:ok, replayed} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert replayed.id == event.id
    refute_received {:tickera_request, _path}
    assert [%DashboardEventGrant{state: "revoked"}] = grants_for_event(event.id)
  end

  test "revalidates identity and creation capability after Tickera preparation" do
    token = Ecto.UUID.generate()
    counts_before = database_counts()

    install_tickera_mock(@tickera_essentials, fn ->
      configure_dashboard_auth(%{username: "changed-dashboard-admin"})
    end)

    assert {:error, :unauthorized} =
             Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())

    assert_tickera_creation_requests()
    assert database_counts() == counts_before
    assert events_for_token(token) == []

    configure_dashboard_auth(%{username: @dashboard_username, event_creation_enabled: true})
    second_token = Ecto.UUID.generate()

    install_tickera_mock(@tickera_essentials, fn ->
      configure_dashboard_auth(%{event_creation_enabled: false})
    end)

    assert {:error, :event_creation_disabled} =
             Events.create_event_for_dashboard(
               @dashboard_username,
               second_token,
               create_attrs()
             )

    assert_tickera_creation_requests()
    assert database_counts() == counts_before
    assert events_for_token(second_token) == []
  end

  test "concurrent requests with one token recover the committed Event across independent sessions" do
    token = Ecto.UUID.generate()
    parent = self()
    install_concurrent_tickera_mock(parent)

    on_exit(fn -> delete_committed_dashboard_event!(token) end)

    assert committed_events_for_token(token) == []

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Events.create_event_for_dashboard(@dashboard_username, token, create_attrs())
          end)
        end)
      end

    try do
      barrier_pids =
        Enum.map(1..2, fn _request ->
          assert_receive {:tickera_essentials_waiting, pid}, 5_000
          pid
        end)

      assert length(Enum.uniq(barrier_pids)) == 2
      Enum.each(barrier_pids, &send(&1, :continue))

      assert [{:ok, first}, {:ok, second}] = Task.await_many(tasks, 15_000)
      assert first.id == second.id

      assert [stored_event] = committed_events_for_token(token)
      assert stored_event.id == first.id

      assert [%DashboardEventGrant{state: "active"} = grant] =
               committed_grants_for_event(first.id)

      assert grant.dashboard_identity == @dashboard_username
      assert grant.granted_by == @dashboard_username
      assert grant.event_id == first.id

      assert %{rows: [[1]]} =
               Sandbox.unboxed_run(Repo, fn -> Repo.query!("SELECT 1") end)
    after
      Enum.each(tasks, fn task -> send(task.pid, :continue) end)
      Enum.each(tasks, &stop_task_if_alive/1)
    end
  end

  defp create_attrs do
    %{
      "tickera_site_url" => "https://voelgoed.co.za",
      "tickera_api_key_encrypted" => "api-key-for-dashboard-create",
      "mobile_access_code" => "scanner-secret-for-dashboard-create"
    }
  end

  defp install_tickera_mock(event_essentials, after_essentials \\ fn -> :ok end) do
    parent = self()

    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""
      send(parent, {:tickera_request, path})

      cond do
        String.ends_with?(path, "/check_credentials") ->
          {:ok, %Response{status: 200, body: %{"pass" => true}}}

        String.ends_with?(path, "/event_essentials") ->
          after_essentials.()

          {:ok, %Response{status: 200, body: Map.put_new(event_essentials, "pass", true)}}

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end

  defp install_concurrent_tickera_mock(parent) do
    Application.put_env(:fastcheck, :tickera_request_fun, fn req ->
      path = req.url.path || ""

      cond do
        String.ends_with?(path, "/check_credentials") ->
          {:ok, %Response{status: 200, body: %{"pass" => true}}}

        String.ends_with?(path, "/event_essentials") ->
          send(parent, {:tickera_essentials_waiting, self()})

          receive do
            :continue ->
              {:ok,
               %Response{
                 status: 200,
                 body: Map.put_new(@tickera_essentials, "pass", true)
               }}
          end

        true ->
          {:ok, %Response{status: 404, body: %{"error" => "not-found"}}}
      end
    end)
  end

  defp assert_tickera_creation_requests do
    assert_receive {:tickera_request, credentials_path}, 1_000
    assert String.ends_with?(credentials_path, "/check_credentials")
    assert_receive {:tickera_request, essentials_path}, 1_000
    assert String.ends_with?(essentials_path, "/event_essentials")
  end

  defp events_for_token(token) do
    Repo.all(from event in Event, where: event.dashboard_creation_token == ^token)
  end

  defp committed_events_for_token(token) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.all(from event in Event, where: event.dashboard_creation_token == ^token)
    end)
  end

  defp database_counts do
    {Repo.aggregate(Event, :count), Repo.aggregate(DashboardEventGrant, :count)}
  end

  defp grants_for_event(event_id) do
    Repo.all(from grant in DashboardEventGrant, where: grant.event_id == ^event_id)
  end

  defp committed_grants_for_event(event_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.all(from grant in DashboardEventGrant, where: grant.event_id == ^event_id)
    end)
  end

  defp delete_committed_dashboard_event!(token) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        event_ids =
          Repo.all(
            from event in Event,
              where: event.dashboard_creation_token == ^token,
              select: event.id
          )

        Repo.delete_all(from grant in DashboardEventGrant, where: grant.event_id in ^event_ids)
        Repo.delete_all(from event in Event, where: event.id in ^event_ids)
      end)
    end)
  end

  defp stop_task_if_alive(%Task{pid: pid} = task) do
    if Process.alive?(pid) do
      case Task.yield(task, 5_000) do
        nil -> Task.shutdown(task, :brutal_kill)
        _result -> :ok
      end
    end
  end

  defp revoke_creator_grant!(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _rows} =
      Repo.update_all(
        from(grant in DashboardEventGrant, where: grant.event_id == ^event_id),
        set: [state: "revoked", revoked_at: now, lock_version: 2]
      )
  end

  defp configure_dashboard_auth(overrides) do
    current = Application.get_env(:fastcheck, :dashboard_auth, %{})
    Application.put_env(:fastcheck, :dashboard_auth, Map.merge(current, overrides))
  end

  defp restore_env(key, nil), do: Application.delete_env(:fastcheck, key)
  defp restore_env(key, value), do: Application.put_env(:fastcheck, key, value)
end
