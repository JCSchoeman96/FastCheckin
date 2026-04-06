# Priority 3 — Poison Queue Handling (Current Baseline and Regression Plan)

**Status:** Rebased execution plan for current `main`  
**Scope:** `android/scanner-app/` only  
**Purpose:** Add quarantine handling for unrecoverable queued scan failures without corrupting live queue truth, local-admission overlay truth, or operator messaging.

---

## 1. Why this priority still exists

Priority 1 changed the Android runtime contract, but it did **not** solve poison-queue handling.

The app is now local-first for gate decisions. Accepted local admissions create:

- a queued scan for durable reconciliation
- a local admission overlay for operational truth

That means a poisoned upload batch is now more dangerous than before:

- it can keep the retry backlog stuck
- it can leave overlays waiting forever for reconciliation
- it can blur operator confidence if the app keeps saying "retry later" for data the backend will never accept

So Priority 3 still matters. In fact, it matters more now.

The core job remains the same:

1. keep retryable backlog in the live queue
2. move unrecoverable rows out of that queue into quarantine
3. preserve enough truth for support/supervisors later
4. surface containment honestly without pretending unrecoverable rows are still retryable

---

## 2. What changed since the old Priority 3 plan

The old plan was directionally correct, but parts of its repo grounding are stale now.

### Correction A — DB version is no longer 6

The old Priority 3 plan assumed quarantine would be the move from database version `6` to `7`.

That is no longer true.

Current `main` is already at **Room database version 7**, and `MIGRATION_6_7` is already used for `local_admission_overlays` [previous Priority 3 baseline](sandbox:/mnt/data/priority-3-poison-queue-handling-pr-plan.md).

So quarantine work must now start from:

- **DB version 7**
- **new migration: `MIGRATION_7_8`**

### Correction B — poison queue now intersects overlay truth

Priority 1 introduced local admission overlays as an operational truth layer. Those overlays transition during flush results:

- `SUCCESS` -> `CONFIRMED_LOCAL_UNSYNCED`
- duplicates / terminal rejections -> conflict states
- retryable/auth-expired -> no overlay resolution yet

Current `CurrentPhoenixMobileScanRepository` already updates overlays from flush outcomes, but it still treats unrecoverable non-401 failures as `WORKER_FAILURE` with the rows left in the live queue. That is exactly the poison-queue gap Priority 3 must close.

### Correction C — quarantine must not accidentally resolve overlays

If a queued row is quarantined, the overlay for that row must **not** be treated as confirmed success.

Quarantine is not server acceptance.
Quarantine is not clean rejection.
Quarantine is containment of unrecoverable local reconciliation state.

### Correction D — the old surfacing plan must now respect merged truth

Queue, Event, Support, and Diagnostics are already used to surface:

- queue/upload truth
- auth-expired/offline/retry semantics
- merged local attendee and overlay truth

So quarantine surfacing must fit into the new local-first runtime rather than the older queue-first mental model.

---

## 3. Repo grounding for current `main`

This plan is written against the repo as it exists **now**, not the earlier pre-Priority-1 baseline.

### Confirmed current state

- `FastCheckDatabase` is already at **version 7** and includes `LocalAdmissionOverlayEntity`.
- `FastCheckDatabaseMigrations` already includes `MIGRATION_6_7` for `local_admission_overlays`.
- `MobileScanRepository` still exposes only queue depth and latest flush report; there is no quarantine summary yet.
- `CurrentPhoenixMobileScanRepository.flushQueuedScans(...)` still treats non-401 unrecoverable HTTP failures and incomplete response-shape failures as `FlushExecutionStatus.WORKER_FAILURE`, with rows left in the live queue.
- `CurrentPhoenixMobileScanRepository` already transitions local admission overlays for successful, duplicate, and terminal flush outcomes.
- `QueueUiState` still has no quarantine fields.
- Event/Support/Diagnostics still have no quarantine model or wording today.

### Current files this priority must respect

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrations.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/QueuedScanEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/LocalAdmissionOverlayEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/MobileScanRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`

### Existing tests to extend

- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt`
- `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrationRetainedQueueTest.kt`
- presenter tests under:
  - `feature/event/`
  - `feature/support/`
  - `feature/diagnostics/`

---

## 4. Non-negotiable runtime truth

These rules must hold across every PR in this priority.

### Rule 1
A quarantined row is **not** a retriable row.

### Rule 2
A quarantined row is **not** silently discarded.

### Rule 3
Live queue depth and quarantine depth are separate truths.

- live queue depth = retriable durable backlog
- quarantine depth = contained unrecoverable backlog

### Rule 4
Auth-expired is not quarantine.

If the token is missing or expired, the queue stays live and re-login remains the recovery path.

### Rule 5
Network/5xx/offline failures are not quarantine.

Those remain retryable.

### Rule 6
The upload API is still batch-based.

If the backend returns an unrecoverable non-401 failure for the attempted batch and does not identify one specific row, the app must not invent row-level certainty.

### Rule 7
Quarantine does not resolve a local admission overlay as success.

If a queued row is quarantined, its overlay must remain unresolved in a truthful containment state until future supervisor/support tooling exists.

### Rule 8
Operator wording must stay calm.

The app should say that bad rows were **contained** and removed from the retry backlog. It must not imply they uploaded successfully.

---

## 5. What this priority should accomplish now

At the end of the rebased Priority 3 work:

- unrecoverable queued scan rows no longer anchor the live retry backlog
- the app preserves the original queued payload truth in a quarantine table
- overlay state remains truthful for quarantined admissions
- Event/Support/Diagnostics can show calm quarantine status
- live retry queue truth remains clean and separate
- future supervisor tooling remains possible without redesigning the persistence model later

---

## 6. What not to do

Reject the implementation if Codex does any of this:

- stores quarantine state as flags inside `queued_scans`
- invents row-level attribution for a batch-level unrecoverable failure
- treats quarantined rows as successful uploads
- resolves overlays as success just because the queue row left the live queue
- merges quarantine count into live queue depth
- redesigns `FlushExecutionStatus` broadly before proving it is needed
- adds supervisor requeue/export/discard screens in this priority
- widens into unrelated queue, auth, or support architecture work

---

## 7. Recommended PR split

Use **three PRs** again, but re-based for current `main`.

### PR 3A — quarantine persistence foundation on top of DB v7
- **Branch:** `codex/priority3-quarantine-foundation-v8`
- **PR title:** `[codex] priority 3 quarantine foundation v8`

### PR 3B — flush containment and overlay-safe quarantine behavior
- **Branch:** `codex/priority3-flush-quarantine-behavior`
- **PR title:** `[codex] priority 3 flush quarantine behavior`

### PR 3C — quarantine surfacing and regression locks
- **Branch:** `codex/priority3-quarantine-surfacing-and-locks`
- **PR title:** `[codex] priority 3 quarantine surfacing and locks`

### Why this split still holds

- **PR 3A** isolates schema and DAO churn
- **PR 3B** changes the hardest runtime behavior: flush containment without false certainty
- **PR 3C** surfaces quarantine to operators/support and locks wording/regressions after the data truth exists

Do not merge UI surfacing before containment exists.

---

## 8. Naming and structure

### Recommended new domain models

Create:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineReason.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineSummary.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/OverlayContainmentState.kt` only if clearly needed

### Recommended new local entity

Create:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/QuarantinedScanEntity.kt`

### Recommended DAO placement

Add quarantine methods to:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`

Do not create a second queue DAO unless there is a compelling reason.

### Why this structure

- queue, overlay, and flush state already live around `ScannerDao`
- quarantine is an extension of local reconciliation persistence, not a new feature surface
- keeping it close reduces churn and keeps review simple

---

## 9. Data model recommendation

## `QuarantinedScanEntity`

Keep this narrow but future-proof.

Recommended fields:

- `id: Long` primary key, autogenerated
- `originalQueueId: Long?`
- `eventId: Long`
- `ticketCode: String`
- `idempotencyKey: String`
- `createdAt: Long`
- `scannedAt: String`
- `direction: String`
- `entranceName: String`
- `operatorName: String`
- `lastAttemptAt: String?`
- `quarantineReason: String`
- `quarantineMessage: String`
- `quarantinedAt: String`
- `batchAttributed: Boolean`
- `overlayStateAtQuarantine: String?`

### Why the extra overlay field matters now

This app now uses overlays as operational truth. Capturing the overlay state at quarantine time gives later tooling/support enough context to understand whether the quarantined row corresponded to:

- a pending local admit
- a confirmed-unsynced local admit
- a conflict state already in progress

Do not overbuild beyond that.

### Recommended indexes

- unique index on `idempotencyKey`
- index on `eventId, quarantinedAt`
- index on `quarantinedAt`

Do not over-index this first slice.

---

## 10. Quarantine reason taxonomy

Keep reasons explicit and small.

Recommended enum values:

- `UNRECOVERABLE_API_CONTRACT_ERROR`
- `INCOMPLETE_SERVER_RESPONSE`
- `UNSUPPORTED_SERVER_RESPONSE_SHAPE`
- `INVALID_PERSISTED_PAYLOAD`
- `BATCH_ATTRIBUTION_UNAVAILABLE`

### Do not include

Do **not** include these as quarantine reasons:

- auth expired
- offline
- retry scheduled
- server 5xx
- network failure

Those are not poison-queue reasons.

---

# 11. PR 3A — Quarantine persistence foundation on top of DB v7

## Goal

Add a dedicated quarantine table and DAO support on top of the existing version-7 database.

## Why this PR comes first

Because the old version-6 baseline is gone. The repo now already uses version 7 for overlays, so quarantine must layer cleanly on top of that instead of colliding with earlier work.

## Must do

- create `QuarantinedScanEntity`
- bump DB version from **7** to **8**
- add `MIGRATION_7_8`
- register the new entity in `FastCheckDatabase`
- add quarantine insert/load/count/summary methods to `ScannerDao`
- add an atomic queue -> quarantine move helper
- add migration and DAO tests

## Must not do

- do not change flush behavior yet
- do not add UI surfacing yet
- do not redesign `FlushExecutionStatus`
- do not touch overlay transition logic yet

## Files to create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/QuarantinedScanEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineReason.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineSummary.kt`

## Files to update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrations.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrationRetainedQueueTest.kt` or a sibling migration test
- DAO tests under `data/local/`

## DAO additions recommended

Add only what PR 3B and PR 3C need.

Recommended methods:

- insert quarantined rows (single and batch)
- count quarantined rows
- observe quarantined row count
- load latest quarantined row
- observe latest quarantine summary or raw pieces needed to build it
- `@Transaction` helper to:
  - insert quarantine rows
  - delete matching queued rows

## Critical transactional rule

The move from live queue to quarantine must be atomic.

Do not insert quarantine rows first and delete queue rows later in repository code.

## Acceptance criteria

- DB builds at version 8
- migration 7 -> 8 succeeds on a DB that already contains overlays
- quarantine table is empty after migration
- current live queue and overlay tables remain intact after migration
- no runtime flush behavior changes yet

## Tests required

### DAO / unit tests

- insert and load quarantined row
- count and observe quarantine count
- latest quarantine row ordering
- atomic queue -> quarantine move helper

### Migration tests

- migrate a v7 DB with queued rows and overlays into v8
- verify queued rows still exist after migration
- verify overlays still exist after migration
- verify quarantine table exists and starts empty
- verify the DB still opens cleanly

## TOON prompt — PR 3A

| Field | Content |
|---|---|
| Task | Implement the quarantine persistence foundation on top of the current Android scanner database version 7. |
| Objective | Add a dedicated quarantine store for unrecoverable queued scans without changing runtime flush behavior yet. |
| Output | Create `QuarantinedScanEntity.kt`, `QuarantineReason.kt`, `QuarantineSummary.kt`; update `FastCheckDatabase.kt`, `FastCheckDatabaseMigrations.kt`, `ScannerDao.kt`; add DAO and migration tests. |
| Note | The database is already at version 7 because Priority 1 introduced `local_admission_overlays`. Quarantine must therefore be a clean `7 -> 8` migration. Use a dedicated quarantine table, not flags on `queued_scans`. Add an atomic DAO helper for queue -> quarantine moves. Do not change flush logic or UI in this PR. |

---

# 12. PR 3B — Flush containment and overlay-safe quarantine behavior

## Goal

Contain unrecoverable upload failures by moving attempted rows out of the live queue while preserving truthful overlay state.

## Must do

- update `CurrentPhoenixMobileScanRepository.flushQueuedScans(...)`
- keep retryable/auth-expired behavior unchanged
- quarantine attempted rows for non-401 unrecoverable failures
- preserve original payload truth in quarantine
- keep overlays unresolved in a truthful way
- add focused repository tests

## Must not do

- do not add quarantine UI yet
- do not add supervisor tooling
- do not invent row-level attribution where the backend does not provide it

## Exact behavior rules

### Keep as retryable

- `IOException`
- HTTP 5xx
- retryable partial backlog

### Keep as auth-expired

- missing token before flush
- HTTP 401

### Quarantine

- non-401 unrecoverable HTTP failures
- incomplete server response shape failures
- malformed/unsupported response payload cases
- impossible persisted payload states discovered during flush handling

## Critical batch-level constraint

When an unrecoverable failure applies to the attempted batch and the backend does not identify one bad row, quarantine the attempted rows together and mark the record as batch-attributed.

Do not guess a culprit row.

## Overlay rule

When a queued row is quarantined:

- do **not** transition the overlay to `CONFIRMED_LOCAL_UNSYNCED`
- do **not** transition it to duplicate/rejected unless the backend actually classified it that way
- keep it in a truthful unresolved containment state

Recommended first-slice approach:

- do not add a brand-new overlay enum unless you genuinely need it
- instead preserve overlay state as-is and let support/event surfacing explain that some unrecoverable queue rows were quarantined

Only add an explicit overlay containment state if repository tests prove the current overlay states are not sufficient.

## Files to update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/MobileScanRepository.kt` only if minimal quarantine summary observation is needed
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- any small mapper/helper files only if required
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt`

## Acceptance criteria

- unrecoverable flush failures no longer anchor the live queue
- retryable rows stay retryable
- auth-expired keeps queue rows live
- quarantined rows preserve original payload truth
- overlay success/rejection transitions still happen only for real classified server outcomes

## Tests required

- non-401 unrecoverable HTTP error quarantines attempted batch rows
- incomplete server response quarantines attempted batch rows
- retryable 5xx leaves rows in queue
- `IOException` leaves rows in queue
- 401 leaves rows in queue and reports auth-expired
- queue depth decreases when rows are quarantined
- quarantine count/summary reflects new quarantined rows
- overlay success transition still happens only for real `SUCCESS`
- quarantine does not fake overlay success
- no silent data loss

## TOON prompt — PR 3B

| Field | Content |
|---|---|
| Task | Implement flush-time quarantine behavior so unrecoverable queued scan failures are removed from the live retry backlog without falsifying overlay or upload truth. |
| Objective | Stop poison rows from anchoring the backlog while preserving local-admission overlay semantics and honest operator/support reporting. |
| Output | Update `CurrentPhoenixMobileScanRepository.kt` and any minimal supporting repository/domain code; add focused repository tests. |
| Note | Keep 401 as auth-expired and keep 5xx/network failures retryable. For non-401 unrecoverable batch failures and incomplete response-shape failures, move attempted rows into quarantine via the new DAO transaction helper. Do not invent row-level certainty when the API only gives batch-level failure. Do not resolve overlays as success just because the queue row left the live queue. Preserve current flush-state shape where possible and prefer truthful summary reporting. |

---

# 13. PR 3C — Quarantine surfacing and regression locks

## Goal

Surface quarantine status calmly in Queue/Event/Support/Diagnostics and lock the wording so future refactors do not blur quarantine with backlog or success.

## Must do

- extend queue/support/event/diagnostics read models with quarantine summary
- keep live queue depth separate from quarantine depth
- add wording and presenter/factory regression tests

## Must not do

- do not add quarantine detail screens
- do not add export/discard/requeue controls
- do not make quarantine more prominent than live queue status when count is zero

## Recommended surfacing strategy

### Queue / upload status

- keep `localQueueDepth` as live retry backlog
- add separate quarantine count and latest reason hint

### Event

Best location:

- queue/upload health section
- recent activity section

Recommended wording examples:

- `Quarantined rows: None`
- `Quarantined rows: 2`
- `Latest quarantine: Unrecoverable API contract error`

### Support

Support should mention containment, not resolution.

Examples:

- `Unrecoverable rows were contained and removed from the retry backlog.`
- `Use Diagnostics for summary details.`

### Diagnostics

Diagnostics can show:

- quarantine count
- latest reason/message
- latest quarantined timestamp

But it must remain read-only.

## Files to update

Likely:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`
- related presenter/factory tests

## Acceptance criteria

- live queue depth remains live retry backlog only
- quarantine count is shown separately when non-zero
- latest quarantine reason/message is visible in calm support/diagnostics surfaces
- wording never implies quarantine is retriable or successful upload
- wording never implies overlays were resolved by quarantine

## Tests required

- queue/event/support/diagnostics presenters show quarantine count separately from queue depth
- zero-quarantine state stays calm and non-noisy
- latest quarantine reason/message wording remains truthful
- auth-expired and offline remain distinct from quarantine
- quarantine wording does not imply success
- quarantine wording does not imply retriable backlog

## TOON prompt — PR 3C

| Field | Content |
|---|---|
| Task | Surface quarantine status in existing operator/support UI and add regression locks so quarantine remains distinct from live queue backlog and successful uploads. |
| Objective | Let operators and support staff see that unrecoverable rows were contained without confusing that with retry backlog, overlay resolution, or server acceptance. |
| Output | Update queue/event/support/diagnostics UI state, presenters/factories, and screens as needed; add focused presenter/factory truth-lock tests. |
| Note | Keep live queue depth and quarantine depth separate. Show only count and latest reason/message. Do not add detail screens or actions in this priority. Keep wording calm and factual: quarantined rows were contained and removed from the retry backlog, not uploaded successfully. Diagnostics stays read-only. |

---

## 14. Merge order

Merge in this order only:

1. **PR 3A — quarantine foundation v8**
2. **PR 3B — flush quarantine behavior**
3. **PR 3C — quarantine surfacing and locks**

Do not invert this order.

---

## 15. Validation commands

Run these after every PR slice.

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

For migration coverage, also run the relevant Android database migration tests already used by the repo.

---

## 16. What success looks like now

Priority 3 succeeds when:

- unrecoverable rows stop blocking the live retry backlog
- original queue payload truth is preserved in quarantine
- queue depth remains honest
- quarantine count is visible separately
- overlay truth is not falsified by containment
- operator/support wording stays calm and accurate
- the implementation does not pretend the batch upload API provides more row-level certainty than it really does

That is the correct current-baseline shape for poison-queue handling after Priority 1.
