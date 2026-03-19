defmodule FastCheck.Load.MobileEventCleanupTest do
  use FastCheck.DataCase, async: false

  import Ecto.Query

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.CheckIn
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Load.MobileEventCleanup
  alias FastCheck.Load.MobileEventSeed
  alias FastCheck.Mobile.MobileIdempotencyLog
  alias FastCheck.Repo
  alias FastCheck.Scans.ScanAttempt

  test "cleans a manifest-targeted performance event and preserves non-perf data" do
    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "mobile-cleanup-manifest-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(manifest_path) end)

    seeded =
      MobileEventSeed.seed!(%{
        attendees: 40,
        credential: "scanner-secret",
        output: manifest_path,
        scanner_code: "ABC123",
        ticket_prefix: "CLEAN"
      })

    regular_event = insert_regular_event!()

    regular_attendee =
      %Attendee{
        allowed_checkins: 1,
        checkins_remaining: 1,
        email: "regular@example.com",
        event_id: regular_event.id,
        first_name: "Regular",
        is_currently_inside: false,
        last_name: "User",
        payment_status: "completed",
        ticket_code: "REG-000001",
        ticket_type: "General"
      }
      |> Repo.insert!()

    seeded_attendee =
      Repo.one!(
        from attendee in Attendee,
          where: attendee.event_id == ^seeded.event.id,
          order_by: [asc: attendee.ticket_code],
          limit: 1
      )

    Repo.insert!(%CheckIn{
      attendee_id: seeded_attendee.id,
      checked_in_at: DateTime.utc_now() |> DateTime.truncate(:second),
      event_id: seeded.event.id,
      status: "success",
      ticket_code: seeded_attendee.ticket_code
    })

    Repo.insert!(%MobileIdempotencyLog{
      event_id: seeded.event.id,
      idempotency_key: "cleanup-idem",
      metadata: %{"source" => "test"},
      result: "success",
      ticket_code: seeded_attendee.ticket_code
    })

    Repo.insert!(%ScanAttempt{
      attendee_id: seeded_attendee.id,
      direction: "in",
      event_id: seeded.event.id,
      idempotency_key: "cleanup-scan-attempt",
      message: "Check-in successful",
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "success",
      ticket_code: seeded_attendee.ticket_code
    })

    result = MobileEventCleanup.cleanup!(manifest: manifest_path)

    assert result.event_ids == [seeded.event.id]
    assert result.deleted.events == 1
    assert result.deleted.attendees == 40
    assert result.deleted.check_ins == 1
    assert result.deleted.mobile_idempotency_logs == 1
    assert result.deleted.scan_attempts == 1
    assert result.deleted.oban_jobs == 0

    refute Repo.get(Event, seeded.event.id)
    assert Repo.get(Event, regular_event.id)
    assert Repo.get(Attendee, regular_attendee.id)
    assert result.redis.strategy == :targeted
  end

  test "marker cleanup removes seeded events when no event id or manifest is provided" do
    seeded =
      MobileEventSeed.seed!(%{
        attendees: 20,
        credential: "scanner-secret",
        scanner_code: "DEF456",
        ticket_prefix: "AUTOZ"
      })

    regular_event = insert_regular_event!()

    result = MobileEventCleanup.cleanup!(%{})

    assert seeded.event.id in result.event_ids
    refute regular_event.id in result.event_ids
    refute Repo.get(Event, seeded.event.id)
    assert Repo.get(Event, regular_event.id)
  end

  defp insert_regular_event! do
    api_key = "regular-api-key-#{System.unique_integer([:positive])}"
    {:ok, encrypted_api_key} = Crypto.encrypt(api_key)
    {:ok, encrypted_secret} = Crypto.encrypt("regular-secret")

    %Event{}
    |> Event.changeset(%{
      checked_in_count: 0,
      mobile_access_secret_encrypted: encrypted_secret,
      name: "Regular Event #{System.unique_integer([:positive])}",
      scanner_login_code: random_scanner_code(),
      site_url: "https://example.com",
      status: "active",
      tickera_api_key_encrypted: encrypted_api_key,
      tickera_api_key_last4: String.slice(api_key, -4, 4),
      tickera_site_url: "https://example.com",
      total_tickets: 1
    })
    |> Repo.insert!()
  end

  defp random_scanner_code do
    Ecto.UUID.generate()
    |> String.replace("-", "")
    |> String.upcase()
    |> String.slice(0, 6)
  end
end
