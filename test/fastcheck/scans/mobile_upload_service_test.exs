defmodule FastCheck.Scans.MobileUploadServiceTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.{
    Crypto,
    Repo,
    Events.Event,
    Attendees.Attendee
  }

  alias FastCheck.Attendees.{CheckIn, CheckInSession}
  alias FastCheck.Scans.{MobileUploadService, ScanAttempt}
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.TestSupport.Scans.InMemoryStore

  setup do
    {:ok, encrypted_secret} = Crypto.encrypt("scanner-secret")

    event =
      %Event{
        name: "Upload Service Event",
        site_url: "https://service.example.com",
        tickera_site_url: "https://service.example.com",
        tickera_api_key_encrypted: "encrypted_key",
        mobile_access_secret_encrypted: encrypted_secret,
        scanner_login_code: unique_scanner_code(),
        status: "active"
      }
      |> Repo.insert!()

    attendee =
      %Attendee{
        event_id: event.id,
        ticket_code: "TEST001",
        first_name: "John",
        last_name: "Doe",
        payment_status: "completed",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    refunded_attendee =
      %Attendee{
        event_id: event.id,
        ticket_code: "REFUND001",
        first_name: "Refunded",
        payment_status: "refunded",
        allowed_checkins: 1,
        checkins_remaining: 1
      }
      |> Repo.insert!()

    original = Application.get_env(:fastcheck, :mobile_scan_ingestion, [])

    InMemoryStore.reset()

    on_exit(fn ->
      Application.put_env(:fastcheck, :mobile_scan_ingestion, original)
      InMemoryStore.reset()
    end)

    %{event: event, attendee: attendee, refunded_attendee: refunded_attendee}
  end

  test "authoritative mode acknowledges only after queueing durability work", %{event: event} do
    configure_mode(:redis_authoritative)

    scan = valid_scan("idem-1", "TEST001")

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event.id, [scan])

    assert [%{worker: worker, args: args}] = all_enqueued(worker: PersistScanBatchJob)
    assert worker == to_string(PersistScanBatchJob)
    assert :ok = perform_job(PersistScanBatchJob, args)

    assert Repo.get_by!(ScanAttempt, event_id: event.id, idempotency_key: "idem-1")
    assert Repo.get_by!(CheckIn, event_id: event.id, ticket_code: "TEST001", status: "success")

    assert Repo.get_by!(CheckInSession,
             event_id: event.id,
             attendee_id: Repo.get_by!(Attendee, event_id: event.id, ticket_code: "TEST001").id
           )

    attendee = Repo.get_by!(Attendee, event_id: event.id, ticket_code: "TEST001")
    assert attendee.checkins_remaining == 0
  end

  test "retry after enqueue failure reuses pending durability and succeeds", %{event: event} do
    configure_mode(:redis_authoritative, force_enqueue_failure: true)

    scan = valid_scan("idem-retry", "TEST001")

    assert {:error, %{code: "durability_enqueue_failed"}} =
             MobileUploadService.upload_batch(event.id, [scan])

    configure_mode(:redis_authoritative)

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event.id, [scan])
    assert {:ok, [%{status: "duplicate"}]} = MobileUploadService.upload_batch(event.id, [scan])
  end

  test "shadow mode does not contaminate the live namespace", %{event: event} do
    configure_mode(:shadow)

    scan = valid_scan("idem-shadow", "TEST001")

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event.id, [scan])

    configure_mode(:redis_authoritative)

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event.id, [scan])
    assert {:ok, [%{status: "duplicate"}]} = MobileUploadService.upload_batch(event.id, [scan])
  end

  test "authoritative mode preserves payment rejection results", %{event: event} do
    configure_mode(:redis_authoritative)

    scan = valid_scan("idem-refund", "REFUND001")

    assert {:ok, [%{status: "error", message: message}]} =
             MobileUploadService.upload_batch(event.id, [scan])

    assert message =~ "Payment invalid"
  end

  defp configure_mode(mode, extra \\ []) do
    Application.put_env(
      :fastcheck,
      :mobile_scan_ingestion,
      Keyword.merge(
        [
          mode: mode,
          chunk_size: 100,
          live_namespace: "live",
          shadow_namespace: "shadow",
          store: InMemoryStore,
          force_enqueue_failure: false
        ],
        extra
      )
    )
  end

  defp valid_scan(idempotency_key, ticket_code) do
    %{
      "idempotency_key" => idempotency_key,
      "ticket_code" => ticket_code,
      "direction" => "in",
      "scanned_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "entrance_name" => "Main Gate",
      "operator_name" => "Scanner 1"
    }
  end

  defp unique_scanner_code do
    System.unique_integer([:positive])
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
