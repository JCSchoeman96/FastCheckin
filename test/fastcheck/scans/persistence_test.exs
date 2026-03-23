defmodule FastCheck.Scans.PersistenceTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.{Attendee, CheckIn, CheckInSession}
  alias FastCheck.Scans.{Persistence, ScanAttempt}

  test "persist_batch is retry-safe for successful authoritative results" do
    event = create_event()

    attendee =
      create_attendee(event, %{
        ticket_code: "PERSIST001",
        allowed_checkins: 1,
        checkins_remaining: 1,
        payment_status: "completed"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      success_result(event.id, attendee.id, attendee.ticket_code, "persist-success-1", now)

    assert :ok = Persistence.persist_batch([result])
    assert :ok = Persistence.persist_batch([result])

    assert Repo.aggregate(
             from(attempt in ScanAttempt,
               where:
                 attempt.event_id == ^event.id and
                   attempt.idempotency_key == ^result.idempotency_key
             ),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(check_in in CheckIn,
               where:
                 check_in.event_id == ^event.id and
                   check_in.ticket_code == ^attendee.ticket_code and
                   check_in.status == "success"
             ),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(session in CheckInSession,
               where: session.event_id == ^event.id and session.attendee_id == ^attendee.id
             ),
             :count,
             :id
           ) == 1

    persisted_attendee = Repo.get!(Attendee, attendee.id)
    assert persisted_attendee.checkins_remaining == 0
    assert persisted_attendee.checked_in_at == now
  end

  test "persist_batch does not create duplicate audit rows for replayed duplicate results" do
    event = create_event()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attendee =
      create_attendee(event, %{
        ticket_code: "PERSISTDUP001",
        allowed_checkins: 1,
        checkins_remaining: 0,
        payment_status: "completed",
        checked_in_at: now
      })

    result =
      duplicate_result(event.id, attendee.id, attendee.ticket_code, "persist-dup-1", now)

    assert :ok = Persistence.persist_batch([result])
    assert :ok = Persistence.persist_batch([result])

    assert Repo.aggregate(
             from(attempt in ScanAttempt,
               where:
                 attempt.event_id == ^event.id and
                   attempt.idempotency_key == ^result.idempotency_key
             ),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(check_in in CheckIn,
               where:
                 check_in.event_id == ^event.id and
                   check_in.ticket_code == ^attendee.ticket_code and
                   check_in.status == "duplicate"
             ),
             :count,
             :id
           ) == 1

    assert Repo.aggregate(
             from(session in CheckInSession,
               where: session.event_id == ^event.id and session.attendee_id == ^attendee.id
             ),
             :count,
             :id
           ) == 0
  end

  defp success_result(event_id, attendee_id, ticket_code, idempotency_key, now) do
    %{
      event_id: event_id,
      attendee_id: attendee_id,
      idempotency_key: idempotency_key,
      ticket_code: ticket_code,
      direction: "in",
      status: "success",
      reason_code: "SUCCESS",
      message: "Check-in successful",
      entrance_name: "Main Gate",
      operator_name: "Scanner 1",
      scanned_at: DateTime.to_iso8601(now),
      processed_at: DateTime.to_iso8601(now),
      hot_state_version: "test-v1",
      metadata: %{
        "remaining_after" => 0,
        "checked_in_at" => DateTime.to_iso8601(now)
      }
    }
  end

  defp duplicate_result(event_id, attendee_id, ticket_code, idempotency_key, now) do
    %{
      event_id: event_id,
      attendee_id: attendee_id,
      idempotency_key: idempotency_key,
      ticket_code: ticket_code,
      direction: "in",
      status: "error",
      reason_code: "DUPLICATE",
      message: "Already checked in: Already checked in at #{DateTime.to_iso8601(now)}",
      entrance_name: "Main Gate",
      operator_name: "Scanner 1",
      scanned_at: DateTime.to_iso8601(now),
      processed_at: DateTime.to_iso8601(now),
      hot_state_version: "test-v1",
      metadata: %{}
    }
  end
end
