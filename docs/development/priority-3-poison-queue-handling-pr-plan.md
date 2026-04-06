# Priority 3 — Poison Queue Handling PR Plan

## Source Baseline

This document refactors and expands the user-provided base priority note for **Priority 3 — Poison queue handling** into an implementation-ready, PR-split execution plan for Codex.

Base priority source:
- `Priority 3 — Poison queue handling.md`

---

## 1. Goal

Prevent unrecoverable queued scan rows from anchoring the live retry backlog while preserving audit truth and operator trust.

This priority is successful when the app can:
- keep retryable queue rows in the live durable queue
- move unrecoverable rows out of that queue into a dedicated quarantine store
- surface calm, truthful operator-facing visibility that bad rows were contained
- preserve enough original data for later supervisor/support handling
- avoid pretending the app can always identify a single bad row when the backend contract only exposes a batch-level failure

---

## 2. Non-Negotiable Runtime Truth

These rules must hold across every PR in this priority.

### Rule 1
A quarantined row is **not** a retriable row.

### Rule 2
A quarantined row is **not** silently discarded.

### Rule 3
Queue depth and quarantine depth are separate truths.
- live queue depth = retriable local backlog
- quarantine depth = contained unrecoverable payloads

### Rule 4
Auth-expired is not quarantine.
A missing/expired token is an operator/session problem, not poisoned payload data.

### Rule 5
Transient network/server failures are not quarantine.
Those remain in the retry queue.

### Rule 6
The current upload API is batch-based.
If the backend returns a non-401 unrecoverable failure for the whole batch, the app may **not** be able to identify one specific bad row. In those cases, the attempted batch may need to be quarantined together.

This is a critical planning truth. Do not let Codex invent per-row certainty where the API does not provide it.

---

## 3. Repo Grounding

Priority 3 must be implemented against the repo as it exists now.

### Confirmed current state
- `CurrentPhoenixMobileScanRepository.flushQueuedScans(...)` currently collapses non-401 unrecoverable HTTP failures and incomplete/invalid response shape failures into `FlushExecutionStatus.WORKER_FAILURE` with no quarantine path.
- `ScannerDao` has no quarantine entity/table/DAO surface today.
- `FastCheckDatabase` is currently at version `6`.
- `FastCheckDatabaseMigrations` currently stops at `MIGRATION_5_6`.
- `MobileScanRepository` exposes queue depth and latest flush report only; no quarantine summary exists yet.
- `QueueUiState` and downstream Event/Scan/Diagnostics surfaces do not model quarantine state.

### Existing files this priority will likely touch
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrations.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/QueuedScanEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/MobileScanRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/*`

### Existing tests to extend or follow
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt`
- `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrationRetainedQueueTest.kt`
- presenter/factory tests under `feature/event/`, `feature/support/`, and `feature/diagnostics/`

---

## 4. What to Challenge Before Coding

The base priority is directionally correct, but several hidden assumptions need to be tightened.

### Assumption to reject 1
"One bad row must not poison the backlog" does **not** always mean "the app can identify the one bad row."

Because upload is batch-based, a non-401 4xx or malformed response may only tell us the **attempted batch** was unrecoverable. If the server gives no row-level attribution, the honest containment strategy is:
- quarantine the attempted batch rows together
- record that the quarantine reason was batch-level and attribution was unavailable

Do not let Codex invent row-level precision that the contract does not provide.

### Assumption to reject 2
Do not add a new broad flush state machine first.

You do **not** need to redesign `FlushExecutionStatus` in the first quarantine slice. The app can preserve current flush-state semantics and add quarantine reporting through:
- summary/report wording
- separate quarantine summary observation
- separate UI badges/counts

Keep the change small.

### Assumption to reject 3
Do not overload `queued_scans` with mixed terminal flags.

A dedicated quarantine table is the cleaner first move because it preserves:
- live retry queue integrity
- operator-visible queue truth
- future supervisor tooling room

### Assumption to reject 4
Do not overbuild supervisor tooling now.

This priority stops at visibility and containment. Full inspect/export/discard/requeue comes later.

---

## 5. Recommended PR Split

Use **three PRs**.

### PR 3A — quarantine persistence foundation
- Branch: `codex/priority3-quarantine-persistence-foundation`
- PR title: `[codex] priority 3 quarantine persistence foundation`

### PR 3B — flush quarantine behavior
- Branch: `codex/priority3-flush-quarantine-behavior`
- PR title: `[codex] priority 3 flush quarantine behavior`

### PR 3C — quarantine surfacing
- Branch: `codex/priority3-quarantine-surfacing`
- PR title: `[codex] priority 3 quarantine surfacing`

### Why this split
- PR 3A changes schema/DAO only and gives a safe base
- PR 3B changes runtime flush behavior with focused repository tests
- PR 3C adds operator/support visibility only after the data truth exists

Do **not** merge UI surfacing before repository behavior exists.

---

## 6. Naming and Structure

### New domain model recommendation
Use explicit quarantine naming and keep it narrow.

Recommended additions:
- `domain/model/QuarantineReason.kt`
- `domain/model/QuarantineSummary.kt`

### New local persistence recommendation
Keep quarantine near the existing local queue persistence.

Recommended additions:
- `data/local/QuarantinedScanEntity.kt`
- DAO additions inside `ScannerDao.kt`

### Why not a separate feature package yet
This priority does not introduce a dedicated quarantine feature screen. It only adds:
- persistence
- repository behavior
- summary surfacing through existing operator/support screens

---

## 7. Data Model Recommendation

## QuarantinedScanEntity

Keep this minimal but support later supervisor tooling.

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

### Why each field matters
- original queue payload fields preserve audit truth
- `originalQueueId` helps correlate local history if needed
- `quarantineReason` provides deterministic semantics
- `quarantineMessage` preserves operator/support-readable failure context
- `quarantinedAt` supports recency and support visibility
- `batchAttributed` avoids false certainty when the whole attempted batch was quarantined due to a non-row-specific failure

### Index guidance
Recommended indexes:
- unique index on `idempotencyKey`
- index on `quarantinedAt`
- index on `eventId, quarantinedAt`

Do not over-index beyond immediate query paths.

---

## 8. Quarantine Reason Taxonomy

Keep reasons small and explicit.

Recommended enum values:
- `UNRECOVERABLE_API_CONTRACT_ERROR`
- `INCOMPLETE_SERVER_RESPONSE`
- `INVALID_PERSISTED_PAYLOAD`
- `UNSUPPORTED_SERVER_RESPONSE_SHAPE`

### What not to include
Do **not** include these as quarantine reasons:
- auth expired
- offline
- network failure
- server 5xx
- retry scheduled

Those remain normal retry/session states.

### Future-only reasons
Do **not** add future-only values like `MANUAL_DISCARD` until supervisor tooling actually exists.

---

## 9. Detailed PR Plans

# PR 3A — Quarantine Persistence Foundation

## Objective
Introduce a dedicated quarantine table, DAO support, migration path, and minimal domain summary support without changing flush behavior yet.

## Scope
### Must do
- add `QuarantinedScanEntity`
- bump DB version from `6` to `7`
- add `MIGRATION_6_7`
- register the entity in `FastCheckDatabase`
- extend `ScannerDao` with quarantine insert/load/count/summary methods
- add migration and DAO tests

### Must not do
- do not change `CurrentPhoenixMobileScanRepository.flushQueuedScans(...)` yet
- do not surface quarantine in UI yet
- do not redesign `FlushExecutionStatus`

## Files to create
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/QuarantinedScanEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineReason.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/QuarantineSummary.kt`

## Files to update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrations.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/androidTest/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrationRetainedQueueTest.kt` or add a sibling migration test
- add focused DAO tests under `data/local/`

## DAO additions recommended
Add only what PR 3B and PR 3C need.

Recommended methods:
- insert quarantined rows (single and batch)
- count quarantined rows
- observe quarantined row count
- load latest quarantined row
- observe latest quarantine summary or enough raw pieces to build it
- transactional helper to move queued rows into quarantine and delete them from `queued_scans`

## Critical transactional rule
The move from live queue to quarantine must be atomic.

Use a DAO `@Transaction` helper such as:
- insert quarantine rows
- delete matching queued rows

Do not insert quarantine rows first and then delete queue rows in separate repository-level calls.

## Acceptance criteria
- DB builds at version 7
- migration 6→7 succeeds on existing queue/runtime DB shape
- quarantine table preserves original scan payload fields
- no live queue behavior changes yet
- no operator-facing UI changes yet

## Tests required
### Unit / DAO tests
- insert and load quarantined row
- count and observe quarantine count
- latest quarantine summary/load ordering
- transaction helper moves row(s) atomically from queue to quarantine

### Migration tests
- migrate a v6 DB with queued rows into v7
- verify queued rows remain intact after migration
- verify quarantine table exists and is empty after migration
- verify runtime DB still opens and queue continues working

## Copy-paste Codex prompt — PR 3A

| Field | Content |
|---|---|
| Task | Implement the quarantine persistence foundation for unrecoverable scan rows in the Android scanner app. |
| Objective | Create a dedicated, auditable quarantine store without changing flush behavior yet, so later PRs can move poisoned rows out of the live retry queue safely. |
| Output | Create `data/local/QuarantinedScanEntity.kt`, `domain/model/QuarantineReason.kt`, `domain/model/QuarantineSummary.kt`; update `core/database/FastCheckDatabase.kt`, `core/database/FastCheckDatabaseMigrations.kt`, and `data/local/ScannerDao.kt`; add DAO and migration tests. |
| Note | Use a dedicated quarantine table, not flags on `queued_scans`. Preserve original queue payload fields plus quarantine reason/message and quarantined timestamp. Bump DB version from 6 to 7 with `MIGRATION_6_7`. Add only the DAO surface needed for later flush behavior and status surfacing. Do not change flush behavior or UI in this PR. The move from queue to quarantine must be supported atomically via DAO transaction helpers. Keep names explicit and code minimal. |

---

# PR 3B — Flush Quarantine Behavior

## Objective
Contain unrecoverable upload failures by moving attempted queue rows into quarantine and preserving truthful flush summaries.

## Scope
### Must do
- update `CurrentPhoenixMobileScanRepository.flushQueuedScans(...)`
- distinguish retryable vs auth-expired vs unrecoverable quarantine paths
- move attempted rows into quarantine atomically when the failure is unrecoverable
- preserve summary/report truth
- extend repository tests

### Must not do
- do not add a dedicated quarantine UI yet
- do not add supervisor inspect/export/requeue
- do not invent row-level attribution where the server does not provide it

## Exact behavior rules
### Keep as retryable
- network `IOException`
- HTTP 5xx
- partial success/unmatched rows already classified as retryable backlog

### Keep as auth-expired
- missing token before flush
- HTTP 401

### Quarantine
- non-401 unrecoverable HTTP errors where retrying is not honest under the current contract
- `IllegalArgumentException` / incomplete response shape failures
- impossible persisted payload / unsupported response shape cases discovered during flush handling

## Critical batch-level constraint
When an unrecoverable failure occurs for the whole attempted batch and the backend does not identify the offending row, quarantine the **attempted batch rows** and record that attribution was batch-level.

Do not guess a single culprit row.

## Recommended repository changes
### Keep existing external shape where possible
Avoid broad interface churn.

Possible interface additions if needed for PR 3C:
- `suspend fun quarantineSummary(): QuarantineSummary?`
- `fun observeQuarantineSummary(): Flow<QuarantineSummary?>`
- `fun observeQuarantineCount(): Flow<Int>`

Do not redesign the whole repository contract.

### Summary/report wording guidance
Preserve current `FlushExecutionStatus` enum initially.

Recommended summary behavior:
- completed with some rows quarantined → still `COMPLETED` if the flush finished classifying the attempted set and removed the quarantined rows from live retry queue
- unrecoverable batch quarantine event can still use a truthful summary like:  
  `Flush quarantined 3 unrecoverable queued scans and cleared them from the live retry backlog.`

Avoid enum explosion in this slice.

## Files to update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/MobileScanRepository.kt` (only if minimal quarantine summary observation is needed)
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- add any small mapper/support helpers only if necessary
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepositoryTest.kt`

## Acceptance criteria
- unrecoverable flush failures no longer leave poisoned rows in live queue
- retryable rows remain retryable
- auth-expired still preserves queue
- quarantined rows preserve original payload truth and reason taxonomy
- repository tests prove queue/quarantine separation

## Tests required
- non-401 unrecoverable HTTP error quarantines attempted batch rows
- incomplete server response quarantines attempted batch rows
- retryable 5xx leaves rows in queue
- `IOException` leaves rows in queue
- 401 leaves rows in queue and reports auth-expired
- queue depth decreases when rows are quarantined
- quarantine count/summary reflects newly quarantined rows
- no silent data loss

## Copy-paste Codex prompt — PR 3B

| Field | Content |
|---|---|
| Task | Implement flush-time quarantine behavior so unrecoverable queued scan failures are contained outside the live retry queue. |
| Objective | Stop poisoned rows from anchoring the backlog while preserving truthful queue, auth, and retry semantics. |
| Output | Update `data/repository/CurrentPhoenixMobileScanRepository.kt` and any minimal repository/domain support needed; add focused repository tests for quarantine behavior. |
| Note | Keep 401 as auth-expired and preserve queue rows. Keep 5xx and network errors retryable. Non-401 unrecoverable batch failures, incomplete server response shapes, and invalid persisted payload states should move the attempted rows into quarantine using the new DAO transaction helper. The upload API is batch-based, so do not invent row-level certainty when the backend only gives batch-level failure. Preserve current flush-state shape where possible; prefer truthful summary messages and separate quarantine summary observation over large enum redesign. |

---

# PR 3C — Quarantine Surfacing

## Objective
Surface quarantine count and latest reason calmly in existing operator/support screens without introducing supervisor tooling yet.

## Scope
### Must do
- extend queue/support/event/diagnostics read models with quarantine summary
- surface count and latest reason/message where helpful
- keep live queue depth separate from quarantine depth
- add presenter/factory tests

### Must not do
- do not add a quarantine detail screen
- do not add export/discard/requeue buttons
- do not make quarantine more prominent than the live queue when it is zero

## Recommended surfacing strategy
### Queue / upload status
- keep `localQueueDepth` as the live retry queue truth
- add separate `quarantineCountLabel` / `quarantineHint`

### Event screen
Best location:
- queue/upload health card
- recent activity card

Recommended wording examples:
- `Quarantined rows: None`
- `Quarantined rows: 2`
- `Latest quarantine: Unrecoverable API contract error`

### Support / diagnostics
- Support overview may mention when bad rows were contained and direct the operator back to normal flow
- Diagnostics can show count and latest summary for support staff

## Avoid these mistakes
- do not call quarantined rows “queued locally”
- do not merge quarantine count into backlog count
- do not present quarantine as a retriable state
- do not imply rows were uploaded successfully

## Files to update
Likely:
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/*`
- related presenter/factory tests

## Acceptance criteria
- queue depth remains live retry queue only
- quarantine count is visible when non-zero
- latest quarantine reason/message is visible in a calm support-facing way
- no operator-facing wording implies quarantine is retriable or confirmed server success

## Tests required
- queue/event/support/diagnostics presenters show quarantine count separately from queue depth
- zero quarantine state stays calm and non-noisy
- latest quarantine reason/message wording remains truthful
- auth-expired and offline states remain distinct from quarantine

## Copy-paste Codex prompt — PR 3C

| Field | Content |
|---|---|
| Task | Surface quarantine status in existing operator/support UI without introducing supervisor tooling yet. |
| Objective | Let operators and supervisors see that unrecoverable rows were contained without confusing quarantine with live queue backlog. |
| Output | Update queue/event/support/diagnostics UI state models, presenters/factories, and screens as needed; add focused presenter/factory tests. |
| Note | Keep live queue depth and quarantine depth separate. Show only count and latest reason/message. Do not add inspect/export/discard/requeue actions in this PR. Avoid noisy UI when quarantine count is zero. Keep wording calm and truthful: quarantined rows were contained and are not part of the retry backlog. |

---

## 10. Merge Order

Merge in this order only:
1. PR 3A — quarantine persistence foundation
2. PR 3B — flush quarantine behavior
3. PR 3C — quarantine surfacing

Do not invert this order.

If UI lands first, it will either stub fake data or force bad repository churn.

---

## 11. Validation Commands

Use the project’s existing validation style.

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

For migration coverage, also run the relevant Android/instrumentation database migration tests already used by the repo.

---

## 12. What to Reject from Codex

Push back if Codex:
- adds quarantine flags onto `queued_scans` instead of a dedicated table
- invents row-level attribution for batch-level unrecoverable failures
- rewrites `FlushExecutionStatus` broadly before proving it is needed
- merges quarantine count into queue depth
- treats auth-expired or offline as quarantine
- adds supervisor tooling in this priority
- silently discards original queue payload fields
- performs queue→quarantine moves outside a transaction

---

## 13. Success Definition

Priority 3 is complete when:
- unrecoverable rows stop blocking the live retry backlog
- the app preserves original payload truth for those rows
- queue depth remains honest
- quarantine count is separately visible
- operator/support wording stays calm and accurate
- the implementation does not pretend the batch upload API provides more row-level certainty than it actually does

That is the right shape for poison-queue handling in this repo.
