defmodule FastCheckWeb.CheckInLoadTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Mobile.Token
  alias FastCheck.Repo

  @moduletag :capture_log

  test "100 concurrent scans stay under 220ms average" do
    previous_disable_occupancy = Application.get_env(:fastcheck, :disable_occupancy_tasks, false)

    previous_disable_stats_broadcast =
      Application.get_env(:fastcheck, :disable_stats_broadcast_tasks, false)

    Application.put_env(:fastcheck, :disable_occupancy_tasks, true)
    Application.put_env(:fastcheck, :disable_stats_broadcast_tasks, true)

    on_exit(fn ->
      Application.put_env(:fastcheck, :disable_occupancy_tasks, previous_disable_occupancy)

      Application.put_env(
        :fastcheck,
        :disable_stats_broadcast_tasks,
        previous_disable_stats_broadcast
      )
    end)

    event = insert_event!("Load Test Event")
    attendees = insert_attendees(event, 150)
    {:ok, token} = Token.issue_scanner_token(event.id)

    scan_codes =
      attendees
      |> Enum.map(& &1.ticket_code)
      |> Enum.take_random(100)

    parent = self()

    results =
      scan_codes
      |> Task.async_stream(
        fn ticket_code ->
          Sandbox.allow(FastCheck.Repo, parent, self())

          conn =
            build_conn()
            |> put_req_header("accept", "application/json")
            |> put_req_header("authorization", "Bearer #{token}")

          payload = %{
            "ticket_code" => ticket_code,
            "entrance_name" => "Load",
            "operator_name" => "LoadTester"
          }

          started = System.monotonic_time(:microsecond)

          response = post(conn, ~p"/api/v1/check-in", payload)
          duration_ms = (System.monotonic_time(:microsecond) - started) / 1000.0

          error_code =
            case Jason.decode(response.resp_body) do
              {:ok, %{"error" => %{"code" => code}}} when is_binary(code) -> code
              _ -> nil
            end

          {response.status, duration_ms, error_code}
        end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, value} -> value end)

    status_counts =
      Enum.frequencies_by(results, fn {status, _duration_ms, _error_code} -> status end)

    non_success_count =
      Enum.reduce(status_counts, 0, fn {status, count}, acc ->
        if status == 200, do: acc, else: acc + count
      end)

    error_codes =
      results
      |> Enum.map(fn {_status, _duration_ms, error_code} -> error_code end)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    assert non_success_count <= 10,
           "Expected <=10 non-success responses, got #{non_success_count}. Status counts: #{inspect(status_counts)} error codes: #{inspect(error_codes)}"

    average_ms =
      results
      |> Enum.filter(fn {status, _duration_ms, _error_code} -> status == 200 end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()
      |> Kernel./(max(status_counts[200] || 0, 1))

    assert average_ms < 220,
           "Average response time #{Float.round(average_ms, 2)}ms exceeded 220ms limit"
  end

  defp insert_event!(name) do
    api_key = "key-#{System.unique_integer([:positive])}"
    {:ok, encrypted} = FastCheck.Crypto.encrypt(api_key)
    {:ok, encrypted_mobile_secret} = FastCheck.Crypto.encrypt("scanner-secret")

    %Event{}
    |> Event.changeset(%{
      name: name,
      tickera_api_key_encrypted: encrypted,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: "https://example.com",
      mobile_access_secret_encrypted: encrypted_mobile_secret
    })
    |> Repo.insert!()
  end

  defp insert_attendees(event, count) do
    for _ <- 1..count do
      %Attendee{}
      |> Attendee.changeset(%{
        event_id: event.id,
        ticket_code: unique_ticket_code(),
        first_name: "Load",
        last_name: "Tester",
        email: "loadtester#{System.unique_integer([:positive])}@example.com",
        payment_status: "completed",
        allowed_checkins: 1,
        checkins_remaining: 1
      })
      |> Repo.insert!()
    end
  end

  defp unique_ticket_code do
    "LOAD-#{System.unique_integer([:positive])}"
  end
end
