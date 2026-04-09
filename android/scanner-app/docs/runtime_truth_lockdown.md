# Runtime Truth Lockdown

This note locks the current Android mobile runtime truth before more scanner
product polish or hardware-adapter work.

## A. Raw Payload Normalization Contract

Android canonicalizes ticket identity by trimming proven scanner boundary whitespace before local lookup, replay suppression, queueing, and upload; structured QR parsing is not promoted.

- Contract tests are the source of truth for the accepted trim vectors.
- Android source adapters still emit raw capture strings, but the shared
  normalizer canonicalizes ticket identity downstream before persistence or
  upload.
- There is no approved client-side structured QR parsing or payload resolver.

- Android currently canonicalizes the captured payload before queueing in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultQueueCapturedScanUseCase.kt`.
- Android preserves that canonical value through queue storage and upload
  mapping in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/mapper/QueuedScanMappers.kt`.
- Android attendee sync canonicalizes backend `ticket_code` before local
  storage in
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`.
- Phoenix currently trims required mobile scan fields during validation in
  `lib/fastcheck/scans/validator.ex` for the covered contract cases.
- Supporting anti-drift tests:
  - `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/core/ticket/TicketCodeNormalizerTest.kt`
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
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

redis_authoritative is now the only supported mobile upload runtime path in this repo; legacy and shadow are no longer supported runtime modes.

- `config/config.exs`, `config/runtime.exs`, and `config/test.exs` no longer expose runtime mode switching for mobile scan upload.
- `lib/fastcheck/scans/mobile_upload_service.ex` runs only the authoritative path.
- Exercised authoritative truth:
  - `docs/mobile_scan_performance.md`
  - `test/fastcheck/scans/mobile_upload_service_test.exs`
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
