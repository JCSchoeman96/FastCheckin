defmodule FastCheckWeb.CheckInLoadTest do
  use FastCheckWeb.ConnCase, async: false

  import Phoenix.ConnTest

  alias Ecto.Adapters.SQL.Sandbox
  alias FastCheck.Attendees.Attendee
  alias FastCheck.Events.Event
  alias FastCheck.Repo

  @moduletag :capture_log

  test "100 concurrent scans stay under 100ms average" do
    event = insert_event!("Load Test Event")
    attendees = insert_attendees(event, 150)

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
            |> put_req_header("content-type", "application/json")

          payload = %{
            "event_id" => event.id,
            "ticket_code" => ticket_code,
            "entrance_name" => "Load",
            "operator_name" => "LoadTester"
          }

          started = System.monotonic_time(:microsecond)

          response = post(conn, ~p"/check-in", Jason.encode!(payload))
          duration_ms = (System.monotonic_time(:microsecond) - started) / 1000.0

          {response.status, duration_ms}
        end,
        max_concurrency: 100,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.all?(results, fn {status, _} -> status == 200 end)

    average_ms =
      results
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()
      |> Kernel./(length(results))

    assert average_ms < 100,
           "Average response time #{Float.round(average_ms, 2)}ms exceeded 100ms limit"
  end

  defp insert_event!(name) do
    %Event{}
    |> Event.changeset(%{
      name: name,
      api_key: "key-#{System.unique_integer([:positive])}",
      site_url: "https://example.com"
    })
    |> Repo.insert!()
  end

  defp insert_attendees(event, count) do
    for _ <- 1..count do
      %Attendee{}
      |> Attendee.changeset(%{
        event_id: event.id,
        ticket_code: unique_ticket_code(),
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
