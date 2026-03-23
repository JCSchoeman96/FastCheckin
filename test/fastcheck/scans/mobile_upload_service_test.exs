defmodule FastCheck.Scans.MobileUploadServiceTest do
  use FastCheck.DataCase, async: false
  use Oban.Testing, repo: FastCheck.Repo

  alias FastCheck.Attendees.Attendee
  alias FastCheck.Attendees.{CheckIn, CheckInSession}
  alias FastCheck.Crypto
  alias FastCheck.Events.Event
  alias FastCheck.Repo
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.Scans.{MobileUploadService, ScanAttempt}
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
    assert_authoritative_mode!()

    event_id = event.id
    scan = valid_scan("idem-1", "TEST001")

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event_id, [scan])

    assert Repo.get_by(ScanAttempt, event_id: event_id, idempotency_key: "idem-1") == nil

    assert Repo.get_by(CheckIn, event_id: event_id, ticket_code: "TEST001", status: "success") ==
             nil

    assert Repo.get_by!(Attendee, event_id: event_id, ticket_code: "TEST001").checkins_remaining ==
             1

    assert [
             %{
               queue: "scan_persistence",
               args: %{
                 "results" => [
                   %{
                     "event_id" => ^event_id,
                     "idempotency_key" => "idem-1",
                     "ticket_code" => "TEST001",
                     "direction" => "in",
                     "status" => "success"
                   }
                 ]
               }
             }
           ] = all_enqueued(worker: PersistScanBatchJob)

    assert [%{args: args}] = all_enqueued(worker: PersistScanBatchJob)
    assert :ok = perform_job(PersistScanBatchJob, args)

    assert Repo.get_by!(ScanAttempt, event_id: event_id, idempotency_key: "idem-1")
    assert Repo.get_by!(CheckIn, event_id: event_id, ticket_code: "TEST001", status: "success")

    assert Repo.get_by!(CheckInSession,
             event_id: event_id,
             attendee_id: Repo.get_by!(Attendee, event_id: event_id, ticket_code: "TEST001").id
           )

    attendee = Repo.get_by!(Attendee, event_id: event_id, ticket_code: "TEST001")
    assert attendee.checkins_remaining == 0
  end

  test "retry after enqueue failure reuses pending durability and succeeds", %{event: event} do
    configure_mode(:redis_authoritative, force_enqueue_failure: true)
    assert_authoritative_mode!()

    scan = valid_scan("idem-retry", "TEST001")

    assert {:error, %{code: "durability_enqueue_failed"}} =
             MobileUploadService.upload_batch(event.id, [scan])

    configure_mode(:redis_authoritative)

    assert {:ok, [%{status: "success"}]} = MobileUploadService.upload_batch(event.id, [scan])

    assert {:ok, [%{status: "duplicate", reason_code: "replay_duplicate"}]} =
             MobileUploadService.upload_batch(event.id, [scan])
  end

  test "shadow mode does not contaminate the live namespace", %{event: event} do
    configure_mode(:shadow)

    shadow_scan = valid_scan("idem-shadow", "TEST001")

    assert {:ok, [%{status: "success"}]} =
             MobileUploadService.upload_batch(event.id, [shadow_scan])

    assert %{
             stage: :pending_durability,
             result: %{idempotency_key: "idem-shadow", ticket_code: "TEST001"}
           } = InMemoryStore.idempotency_entry("shadow", event.id, "idem-shadow")

    assert nil == InMemoryStore.idempotency_entry("live", event.id, "idem-shadow")

    %Attendee{
      event_id: event.id,
      ticket_code: "TEST002",
      first_name: "Jane",
      last_name: "Doe",
      payment_status: "completed",
      allowed_checkins: 1,
      checkins_remaining: 1
    }
    |> Repo.insert!()

    configure_mode(:redis_authoritative)

    authoritative_scan = valid_scan("idem-live-1", "TEST002")

    assert {:ok, [%{status: "success"}]} =
             MobileUploadService.upload_batch(event.id, [authoritative_scan])

    assert {:ok, [%{status: "duplicate"}]} =
             MobileUploadService.upload_batch(event.id, [authoritative_scan])
  end

  test "authoritative mode preserves payment rejection results", %{event: event} do
    configure_mode(:redis_authoritative)
    assert_authoritative_mode!()

    scan = valid_scan("idem-refund", "REFUND001")

    assert {:ok, [%{status: "error", message: message, reason_code: "payment_invalid"}]} =
             MobileUploadService.upload_batch(event.id, [scan])

    assert message =~ "Payment invalid"
  end

  test "authoritative mode maps business duplicates without using raw result status semantics", %{
    event: event
  } do
    configure_mode(:redis_authoritative)
    assert_authoritative_mode!()

    first_scan = valid_scan("idem-business-1", "TEST001")
    second_scan = valid_scan("idem-business-2", "TEST001")

    assert {:ok, [%{status: "success"}]} =
             MobileUploadService.upload_batch(event.id, [first_scan])

    assert {:ok, [%{status: "error", reason_code: "business_duplicate", message: message}]} =
             MobileUploadService.upload_batch(event.id, [second_scan])

    assert message =~ "Already checked in"
  end

  test "authoritative mode surfaces build-timeout hot-state failures", %{event: event} do
    namespace = unique_namespace("build-timeout")

    configure_mode(:redis_authoritative,
      live_namespace: namespace,
      shadow_namespace: "#{namespace}-shadow"
    )

    assert_authoritative_mode!()
    InMemoryStore.inject_process_error(namespace, :build_timeout)

    scan = valid_scan("idem-build-timeout", "TEST001")

    assert {:error, %{code: "scan_hot_state_unavailable", message: message}} =
             MobileUploadService.upload_batch(event.id, [scan])

    assert message =~ "Unable to prepare event scan state"
    assert all_enqueued(worker: PersistScanBatchJob) == []
  end

  test "authoritative mode surfaces promotion failures without false success", %{event: event} do
    namespace = unique_namespace("promotion")

    configure_mode(:redis_authoritative,
      live_namespace: namespace,
      shadow_namespace: "#{namespace}-shadow"
    )

    assert_authoritative_mode!()
    InMemoryStore.inject_promote_error(namespace, :promotion_failed)

    scan = valid_scan("idem-promotion-fail", "TEST001")

    assert {:error, %{code: "scan_result_promotion_failed", message: message}} =
             MobileUploadService.upload_batch(event.id, [scan])

    assert message =~ "Unable to finalize acknowledged scan results"

    assert [%{args: _args}] = all_enqueued(worker: PersistScanBatchJob)

    assert %{
             stage: :pending_durability,
             result: %{idempotency_key: "idem-promotion-fail", ticket_code: "TEST001"}
           } = InMemoryStore.idempotency_entry(namespace, event.id, "idem-promotion-fail")

    assert Repo.get_by(ScanAttempt, event_id: event.id, idempotency_key: "idem-promotion-fail") ==
             nil
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

  defp assert_authoritative_mode! do
    assert MobileUploadService.ingestion_mode() == :redis_authoritative
    assert MobileUploadService.authoritative_mode?()
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

  defp unique_namespace(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
