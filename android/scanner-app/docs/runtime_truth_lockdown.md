# Runtime Truth Lockdown

This note locks the current Android mobile runtime truth before more scanner
product polish or hardware-adapter work.

## A. Raw Payload Normalization Contract

Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted.

- Android sends the raw scanned payload as `ticket_code` unchanged today.
- There is no approved client-side normalization policy today.
- The only proven backend-side normalization today is required-field trimming in
  Phoenix validation. No broader QR normalization or scanned-payload mapping
  policy is promoted.

- Android currently queues the captured payload as `ticketCode` in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultQueueCapturedScanUseCase.kt`.
- Android preserves that exact value through queue storage and upload mapping in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/mapper/QueuedScanMappers.kt`.
- Android attendee sync also preserves backend `ticket_code` exactly as
  delivered in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`.
- Phoenix currently trims required mobile scan fields during validation in
  `lib/fastcheck/scans/validator.ex`.
- That trimming is the only proven backend-side normalization here. It does not
  promote a broader QR normalization or scanned-payload-to-ticket mapping
  policy.
- Supporting anti-drift tests:
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
  - `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/mapper/QueuedScanMappersTest.kt`
  - `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt`
  - `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/RuntimeContractAuditTest.kt`

## B. Direction Truth

Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.

- Active Android UI and use cases currently enqueue only `ScanDirection.IN`.
- The Android model still contains `OUT`, but that is not promoted runtime
  support.
- Phoenix validation still accepts `"out"` syntactically in
  `lib/fastcheck/scans/validator.ex`.
- The actual mobile execution paths reject it as not implemented in:
  - `lib/fastcheck/scans/legacy_upload_service.ex`
  - `lib/fastcheck/scans/hot_state/redis_store.ex`
- Supporting anti-drift tests:
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
  - `test/fastcheck/scans/mobile_upload_service_test.exs`
  - `test/fastcheck/scans/hot_state/redis_store_test.exs`
  - `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/RuntimeContractAuditTest.kt`

## C. Ingestion Mode Truth

redis_authoritative is the target/proven path in tests and perf; legacy and shadow are fallback/migration modes; deployed production truth cannot be proven from repo code alone.

- Repo default and fallback truth today is `legacy`.
- Exercised authoritative truth today is `redis_authoritative`.
- Deployed production truth remains unproven from repo code alone.

- Repo default and fallback truth:
  - `config/config.exs` sets `:legacy`
  - `config/test.exs` sets `:legacy`
- Runtime override truth:
  - `config/runtime.exs` resolves `MOBILE_SCAN_INGESTION_MODE`
  - `lib/fastcheck/scans/ingestion_mode.ex` defines the exact mapping and
    fallback rules
- Exercised authoritative truth:
  - `README.md`
  - `docs/mobile_scan_performance.md`
  - `test/fastcheck/scans/mobile_upload_service_test.exs`
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- Deployed production truth:
  - not provable from repo code alone because live deployment environment
    variables are outside this repository
