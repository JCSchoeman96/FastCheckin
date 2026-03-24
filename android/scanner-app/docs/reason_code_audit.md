# Android `reason_code` Audit

## Result Path

The active Android `/api/v1/mobile/scans` result path is:

1. [`RemoteModels.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/remote/RemoteModels.kt)
2. [`FlushResultClassifier.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifier.kt)
3. [`CurrentPhoenixMobileScanRepository.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt)
4. [`QueuedScanMappers.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/mapper/QueuedScanMappers.kt)
5. [`FlushReport.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt)
6. [`RecentFlushOutcomeEntity.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/RecentFlushOutcomeEntity.kt) and Room-backed flush history
7. [`DiagnosticsViewModel.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsViewModel.kt)
8. [`DiagnosticsUiStateFactory.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt)

## Decision

- `status` remains the primary runtime behavior key.
- `reason_code` is optional and additive.
- Missing result rows after HTTP 200 remain retryable.
- `message` is never parsed into business truth.
- Proven refinements remain only `replay_duplicate`, `business_duplicate`, and `payment_invalid`.
- Concurrent same-idempotency ambiguity remains broad unless the backend emits a final replay reason.

## Persistence Decision

`reason_code` must be persisted in Room-backed flush history. Diagnostics project persisted [`FlushReport.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt) state plus live coordinator state, not DTO-only ephemeral upload rows. If Android dropped `reason_code` after classification, later diagnostics projections could not refine proven server truth from persisted outcomes.

`FlushItemOutcome` stays unchanged. The smallest honest model is to keep the broad outcome enum and carry `reasonCode: String?` alongside it for projection and history only.

Queue truth remains low-noise. [`QueueViewModel.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueViewModel.kt) and [`QueueUiStateFactory.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiStateFactory.kt) stay focused on queue depth and flush state, while diagnostics read persisted flush state plus live coordinator state.

## Test Impact Map

- [`FlushResultClassifierTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifierTest.kt)
  - Anti-drift seam: `status` and row presence still control runtime outcome class.
  - Required cases: replay duplicate, missing `reason_code`, business duplicate terminal error, payment invalid, unknown reason, success with unexpected reason, missing row retryability.
- [`CurrentPhoenixMobileScanRepositoryTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt)
  - Anti-drift seam: queue removal, retry retention, auth expiry, network/server retry behavior, and replay-cache non-dependence stay unchanged.
- [`DiagnosticsUiStateFactoryTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactoryTest.kt)
  - Anti-drift seam: refined wording appears only for proven persisted `reasonCode` cases and never from `message`.
- [`RuntimeContractAuditTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/RuntimeContractAuditTest.kt)
  - Anti-drift seam: Android stays on `/api/v1/mobile/*`, does not branch on `message`, and keeps the broad `FlushItemOutcome` model.
- [`ScannerDaoTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt)
  - Anti-drift seam: persisted non-null `reasonCode` round-trips and latest-flush replacement preserves ordering.
- [`FastCheckDatabaseMigrationTest.kt`](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrationTest.kt)
  - Anti-drift seam: version 2 installs upgrade cleanly to version 3, old null rows remain readable, and post-migration non-null `reasonCode` writes are safe.
