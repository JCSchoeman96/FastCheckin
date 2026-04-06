# Priority 4 — Current Baseline and Regression Plan

**Status:** Rebased on current `main` after Priority 1 local-admission runtime landed  
**Scope:** `android/scanner-app/` only  
**Purpose:** Remove destructive `REPLACE` semantics from the two critical Room write paths that still matter most in production: attendee persistence and sync metadata persistence.

---

## 1. Goal

Harden the Android scanner app’s most important sync-time writes without changing the current progressive sync runtime.

This priority succeeds when the app:

- stops using `OnConflictStrategy.REPLACE` for attendee persistence
- stops using `OnConflictStrategy.REPLACE` for sync metadata persistence
- preserves page-at-a-time attendee sync writes
- preserves the current truth that attendee rows may be ahead of sync metadata after a later-page failure
- preserves the current rule that sync metadata only advances after a fully successful sync
- adds enough regression protection that future refactors cannot quietly reintroduce destructive write behavior

This is **not** a product-surface feature.
This is a correctness and durability refactor.

---

## 2. Current Verdict

Priority 4 remains valid.

It did **not** get displaced by the new local-first runtime that landed in Priority 1.
But it must now be written against the repo as it exists **today**, not the older baseline.

### What changed since the older Priority 4 plan

The older plan was broadly correct, but the repo moved forward in these important ways:

- the Android scanner runtime is now explicitly **local-first**
- `local_admission_overlays` already exist in Room
- database version is already **7**
- the sync path now resolves confirmed overlays after sync catch-up
- the scanner app still uses `REPLACE` on the exact two write paths this priority was meant to clean up

### What did **not** change

The core problem is still the same:

- `ScannerDao.upsertAttendees(...)` still uses `REPLACE`
- `ScannerDao.upsertSyncMetadata(...)` still uses `REPLACE`
- `CurrentPhoenixSyncRepository.syncAttendees()` still writes attendees page-by-page, then writes metadata after the full sync succeeds

So the central task remains:

> Replace destructive `REPLACE` semantics on attendee rows and sync metadata rows **without** changing the existing progressive sync behavior.

---

## 3. Repo Grounding

This plan is based on the current `main` branch.

### Confirmed current state

`ScannerDao` still uses `@Insert(onConflict = OnConflictStrategy.REPLACE)` for:

- `upsertAttendees(attendees: List<AttendeeEntity>)`
- `upsertSyncMetadata(metadata: SyncMetadataEntity)`

It also still uses `REPLACE` for several other persistence paths, but those remain **out of scope** for this priority:

- local admission overlays
n- replay cache
- replay suppression
- latest flush snapshot
- recent flush outcomes

`CurrentPhoenixSyncRepository.syncAttendees()` still:

1. loads the current session
2. loads existing sync metadata
3. fetches attendees page-by-page
4. persists each page immediately through `scannerDao.upsertAttendees(...)`
5. only after the full paged sync succeeds, persists metadata through `scannerDao.upsertSyncMetadata(...)`
6. then resolves `CONFIRMED_LOCAL_UNSYNCED` overlays that the synced attendee base row has caught up with

That progressive sync shape is already correct and must **not** be rewritten.

### Existing files this priority must respect

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`
- `android/scanner-app/app/build.gradle.kts`

### Existing truths already locked by current tests

The current repo already has strong tests that must remain true after this refactor.

#### Truth 1 — Progressive sync stays page-at-a-time
`CurrentPhoenixSyncRepositoryTest` already proves that paged sync fetches and persists incrementally rather than buffering the whole dataset.

#### Truth 2 — Earlier successful pages remain persisted after a later failure
Current tests already prove that if a later page fails, earlier pages remain locally written.

#### Truth 3 — Metadata remains at the last fully successful sync boundary
Current tests already prove that metadata does **not** advance just because an earlier page was written successfully.

#### Truth 4 — Metadata write failure must not wipe attendee writes
There is already a test proving that attendee rows can remain ahead of metadata when metadata write fails late.

#### Truth 5 — Room baseline already supports `@Upsert`
The app is already on Room `2.8.4`, so `@Upsert` is available if it keeps the implementation clean and minimal.

---

## 4. Why this priority still matters

`REPLACE` is still the wrong semantic tool on the two most important sync persistence paths.

### Attendee persistence
Using `REPLACE` for attendees is blunt.
Even when it appears to work, SQLite implements it as delete-then-insert behavior.
That is the wrong fit for frequently updated local base truth.

### Sync metadata persistence
Using `REPLACE` for sync metadata is also blunt.
This row is not just another record. It is the marker for the **last fully successful sync boundary**.
That should be updated precisely, not destructively.

### Why this matters more now
After Priority 1, the repo now depends more heavily on clear truth boundaries:

- attendee rows are server-synced base truth
- overlays are operational truth
- sync metadata marks trusted sync readiness for current event admission

That makes precise local write semantics more important, not less.

---

## 5. Non-negotiable Runtime Rules

These rules are mandatory.

### Rule 1
Do not change the sync API contract.

### Rule 2
Do not change the progressive sync algorithm shape.

### Rule 3
Do not buffer all sync pages in memory and write once.

### Rule 4
Do not “fix” attendee-ahead-of-metadata behavior.
That is an intentional property of the current runtime.

### Rule 5
Do not widen this priority into replay cache, replay suppression, flush snapshot, or recent flush outcome cleanup.

### Rule 6
Do not add a schema change or database version bump unless there is a real schema need.
There should likely be **no migration** in this priority.

### Rule 7
Keep code boring and explicit.
This is not the place for clever abstractions.

---

## 6. Success Looks Like

At the end of Priority 4:

- attendee writes no longer rely on `REPLACE`
- sync metadata writes no longer rely on `REPLACE`
- current progressive sync behavior is preserved exactly
- local admission overlay catch-up behavior still works after sync
- existing sync failure semantics remain intact
- new tests make future regression obvious
- unrelated persistence paths remain untouched for now

---

## 7. Scope Boundaries

## In scope

- attendee DAO write semantics
- sync metadata DAO write semantics
- minimal `CurrentPhoenixSyncRepository` adjustments needed to use those new DAO semantics cleanly
- DAO and repository tests for regression locking
- comments only where they materially clarify sync-boundary truth

## Out of scope

- overlay persistence semantics
- replay cache write semantics
- replay suppression write semantics
- latest flush snapshot semantics
- recent flush outcome semantics
- queue persistence redesign
- quarantine / poison queue handling
- Event / Search / Scan / Support / Diagnostics UI changes
- Room schema changes unless truly unavoidable

---

## 8. Recommended PR Split

Use **three PRs**.

Do not collapse them into one broad persistence refactor.

### PR 4A — attendee upsert semantics
- **Branch:** `codex/priority4-attendee-upsert-semantics`
- **PR title:** `[codex] priority 4 attendee upsert semantics`

### PR 4B — sync metadata write integrity
- **Branch:** `codex/priority4-sync-metadata-write-integrity`
- **PR title:** `[codex] priority 4 sync metadata write integrity`

### PR 4C — progressive sync regression locks
- **Branch:** `codex/priority4-progressive-sync-regression-locks`
- **PR title:** `[codex] priority 4 progressive sync regression locks`

### Why this split

- **PR 4A** removes `REPLACE` from the highest-volume base-truth write path first
- **PR 4B** removes `REPLACE` from the metadata boundary path second
- **PR 4C** turns the subtle existing behavior into explicit long-term regression protection

---

## 9. Recommended Worktree Setup

```bash
git fetch origin

git worktree add ../fastcheck-priority4a -b codex/priority4-attendee-upsert-semantics origin/main
git worktree add ../fastcheck-priority4b -b codex/priority4-sync-metadata-write-integrity origin/main
git worktree add ../fastcheck-priority4c -b codex/priority4-progressive-sync-regression-locks origin/main
```

Use a normal stacked flow:

- PR 4A from `main`
- PR 4B from PR 4A branch tip
- PR 4C from PR 4B branch tip

---

# 10. PR 4A — Attendee Upsert Semantics

## 10.1 Goal

Replace destructive attendee `REPLACE` semantics with proper upsert behavior while preserving the current paged sync flow.

## 10.2 Why this PR comes first

This is the highest-volume write path and the easiest place to reduce destructive semantics without muddying sync-boundary semantics.

## 10.3 Files to change

### Primary
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`

### Tests
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

## 10.4 Exact implementation requirements

### DAO direction
Preferred:

- replace attendee `@Insert(REPLACE)` with `@Upsert`

Acceptable fallback if needed:

- insert-ignore + update
- explicit update + insert-missing helper
- narrow transaction helper only if required for clarity

### Keep the entrypoint stable if possible
Prefer to keep the current DAO method name:

- `upsertAttendees(attendees: List<AttendeeEntity>)`

That keeps churn low.

### Repository behavior
`CurrentPhoenixSyncRepository.syncAttendees()` must keep this exact shape:

- fetch one page
- canonicalize ticket codes for that page
- write that page immediately
- continue pagination
- only after the full sync succeeds, persist sync metadata

Do not widen this PR into metadata write refactoring unless compilation requires a very small shared adjustment.

## 10.5 Edge cases to protect

- repeated sync of the same attendee ID with updated fields
- repeated sync of the same `(eventId, ticketCode)` identity
- updated email/name/payment/inside-state fields
- later-page failure after earlier page writes
- ticket-code canonicalization still being the local lookup key
- overlay catch-up still resolving against the synced base row after a successful full sync

## 10.6 Acceptance criteria

- attendee write path no longer uses `REPLACE`
- progressive page writes still work
- existing paged-sync failure semantics still hold
- no schema change introduced
- no unrelated DAO semantics touched

## 10.7 Required tests for PR 4A

### DAO tests
Add or tighten tests for:

- attendee row update through the new attendee upsert path
- repeated attendee upsert keeps latest field values
- attendee lookup by `(eventId, ticketCode)` still works after repeated updates

### Repository tests
Keep and extend tests for:

- paged sync persists earlier pages before a later failure
- invalid ticket code on a later page does not wipe earlier attendee rows
- repeated cursor failure still leaves earlier persisted pages intact

### Explicit regression tests to add

- replacing attendee fields through the new semantics does not require destructive `REPLACE`
- late failure still leaves earlier attendee rows in place
- no heap-heavy collect-all-pages behavior is introduced

## 10.8 Out of scope

- sync metadata semantics
- replay cache / replay suppression cleanup
- overlay persistence changes
- schema migration

## 10.9 TOON prompt — PR 4A

| Field | Content |
|---|---|
| Task | Replace destructive `REPLACE` semantics for attendee persistence with proper upsert behavior in the Android scanner app. |
| Objective | Remove delete-then-insert behavior from the highest-volume local base-truth write path while preserving page-at-a-time attendee sync. |
| Output | Update `data/local/ScannerDao.kt`, make any minimal repository call-site adjustments in `data/repository/CurrentPhoenixSyncRepository.kt`, and expand focused DAO/repository tests. |
| Note | Prefer `@Upsert` because Room 2.8.4 is already available. Preserve progressive page writes. Do not change sync metadata semantics in this PR unless minimally required for compilation. Do not widen into replay cache, replay suppression, overlays, or UI work. No schema migration unless truly necessary. |

---

# 11. PR 4B — Sync Metadata Write Integrity

## 11.1 Goal

Replace `REPLACE` semantics for sync metadata with precise update/upsert behavior while preserving the current sync-boundary truth.

## 11.2 Why this PR is separate

Sync metadata is not just another table write.
It represents the last fully successful sync boundary used by the runtime.

That deserves its own review slice.

## 11.3 Files to change

### Primary
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`

### Tests
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

## 11.4 Exact implementation requirements

### DAO direction
Preferred:

- replace metadata `@Insert(REPLACE)` with `@Upsert`

Acceptable fallback:

- explicit insert/update helper with clean semantics

### Preserve current repository ordering
`CurrentPhoenixSyncRepository.syncAttendees()` must still:

- write attendees progressively page by page
- only after the full sync succeeds, write metadata once
- after metadata write, run confirmed-overlay catch-up resolution

Do **not** wrap the entire paged sync in one giant transaction.

### Preserve helper semantics carefully
`ScannerDao.upsertAttendeesAndSyncMetadata(...)` currently exists as a helper and current tests already lock its transactional rollback behavior.

If Codex keeps this helper, it must call the **new** attendee and metadata semantics while preserving its atomic helper behavior.

If Codex removes or renames it, that change must be justified and current atomic-helper tests must be replaced with equally strong coverage.

## 11.5 Edge cases to protect

- metadata insert when no row exists yet
- metadata update when row already exists
- metadata write failure after attendees were already progressively persisted
- metadata still reflecting last fully successful sync after later failure
- current event sync readiness continuing to depend on the same metadata truth

## 11.6 Acceptance criteria

- metadata write path no longer uses `REPLACE`
- metadata still advances only after full sync success
- attendee-ahead-of-metadata behavior remains intact on late failure
- overlay catch-up still runs only after successful metadata write path
- no schema migration introduced

## 11.7 Required tests for PR 4B

### DAO tests
Keep or expand tests for:

- helper persists attendees and metadata through one DAO boundary
- helper rolls back attendee write when metadata write fails
- helper does not write metadata when attendee write fails

### Repository tests
Keep and extend tests for:

- successful sync persists metadata at the end
- metadata write failure leaves earlier attendee writes intact
- metadata remains at the prior successful boundary after failure
- current sync status continues to read from the same row semantics

### Explicit regression tests to add

- metadata upsert path updates existing row without destructive `REPLACE`
- overlay catch-up still occurs after successful sync completion
- sync metadata remains untouched on later-page failure

## 11.8 Out of scope

- broad sync algorithm rewrite
- UI or support wording changes
- replay cache / flush snapshot cleanup
- database version bump

## 11.9 TOON prompt — PR 4B

| Field | Content |
|---|---|
| Task | Replace `REPLACE` semantics for sync metadata with precise update/upsert behavior and preserve the current sync-boundary truth. |
| Objective | Keep sync metadata truthful as the last fully successful sync boundary without destructive delete-then-insert writes. |
| Output | Update `data/local/ScannerDao.kt`, `data/repository/CurrentPhoenixSyncRepository.kt`, and strengthen focused DAO/repository tests. |
| Note | Preserve the current model where attendee rows may be ahead of metadata after a failed later page. Do not wrap the entire paged sync in one global transaction. Metadata must still advance only after the full sync succeeds. Keep the atomic helper semantics tested if the helper remains. No unrelated persistence refactors. |

---

# 12. PR 4C — Progressive Sync Regression Locks

## 12.1 Goal

Lock the current sync guarantees explicitly so future refactors cannot quietly reintroduce destructive semantics or change sync-boundary truth.

## 12.2 Why this PR must exist

This priority is easy to fake with a DAO annotation swap and too little regression protection.

This PR makes the guarantees obvious.

## 12.3 Files to change

### Tests only, ideally
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

### Optional small comments only if truly helpful
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`

## 12.4 What to lock explicitly

Add or tighten tests for:

1. repeated attendee updates no longer depend on destructive replace semantics
2. page-at-a-time persistence still works
3. earlier successful pages survive later-page failure
4. metadata remains at prior successful boundary on failure
5. metadata write failure does not wipe earlier attendee writes
6. overlay catch-up still only happens after successful full sync completion
7. helper semantics remain atomic if helper remains in the DAO

## 12.5 Required regression suite

### ScannerDaoTest additions
Add explicit tests for:

- attendee upsert updates an existing attendee row cleanly
- sync metadata upsert updates an existing row cleanly
- helper path still rolls back correctly on failure
- no helper success path regresses

### CurrentPhoenixSyncRepositoryTest additions
Add explicit tests for:

- page-at-a-time attendee writes remain intact
- metadata lag on later-page failure remains intact
- metadata write failure leaves attendee writes intact
- successful sync still resolves `CONFIRMED_LOCAL_UNSYNCED` overlays only after metadata commit path

### Optional high-value test
If cheap and stable, add a targeted repository test that seeds a `CONFIRMED_LOCAL_UNSYNCED` overlay and proves it gets deleted only after a successful sync whose attendee base row satisfies catch-up policy.

## 12.6 Acceptance criteria

- tests clearly communicate the intended sync semantics
- future destructive write reintroduction becomes harder to slip in
- no UI changes
- no schema migration

## 12.7 Out of scope

- instrumentation churn without need
- replay cache / flush snapshot write cleanup
- UI or diagnostics changes

## 12.8 TOON prompt — PR 4C

| Field | Content |
|---|---|
| Task | Add regression tests that lock the current paged-sync and precise-write semantics after the attendee and sync metadata refactors. |
| Objective | Prevent future regressions that reintroduce destructive `REPLACE` behavior or blur the sync-boundary truth. |
| Output | Expanded tests in `data/local/ScannerDaoTest.kt` and `data/repository/CurrentPhoenixSyncRepositoryTest.kt`, plus only minimal comments where they materially improve clarity. |
| Note | Lock repeated attendee updates, partial page persistence, metadata lag on failed later pages, metadata write failure behavior, and successful overlay catch-up timing. Keep this PR test-focused. Do not widen into replay cache, flush snapshot, overlays persistence semantics, or UI work. |

---

## 13. Risks, Failure Modes, and Review Traps

### Main failure modes

1. **Codex swaps `REPLACE` to `@Upsert` without proving behavior with tests**  
   That is not enough on its own.

2. **Codex “fixes” attendee-ahead-of-metadata behavior**  
   That would be a semantic rewrite, not this priority.

3. **Codex wraps the entire paged sync in one transaction**  
   That would undo the current progressive persistence design.

4. **Codex widens into replay cache / replay suppression / flush snapshot cleanup**  
   Out of scope.

5. **Codex adds a schema change or DB version bump without a real schema need**  
   That is unnecessary churn.

6. **Codex breaks overlay catch-up after successful sync**  
   That would be a real regression under the new runtime.

### Review questions for every PR

- Did this remove `REPLACE` from the targeted path?
- Did this preserve page-at-a-time attendee writes?
- Did this preserve metadata-boundary truth?
- Did this avoid widening into unrelated persistence paths?
- Did this avoid a schema change unless truly necessary?
- Did this preserve post-sync overlay catch-up behavior?

---

## 14. Merge Order

Merge in this order only:

1. **PR 4A — attendee upsert semantics**
2. **PR 4B — sync metadata write integrity**
3. **PR 4C — progressive sync regression locks**

Do not invert this order.

---

## 15. Validation Commands

Run after every PR slice.

```bash
git diff --check

JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 \
bash ./gradlew \
  -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 \
  :app:compileDebugKotlin \
  :app:testDebugUnitTest
```

This priority should not require a migration.
If Codex introduces one anyway, stop and justify it before proceeding.

---

## 16. What to Reject from Codex

Reject the PR if Codex does any of this:

- leaves `REPLACE` on attendee or sync metadata writes
- rewrites the whole sync algorithm
- buffers all pages in memory before writing
- “fixes” attendee-ahead-of-metadata behavior
- widens into replay cache / flush snapshot / replay suppression cleanup
- adds a database version bump without a real schema need
- breaks overlay catch-up after successful sync
- broadens into unrelated UI or product-surface work

---

## 17. What Success Looks Like

Priority 4 succeeds when:

- attendee sync writes stop relying on destructive `REPLACE`
- sync metadata writes stop relying on destructive `REPLACE`
- progressive page persistence remains intact
- metadata still marks the last fully successful sync boundary
- overlays still resolve only after successful sync catch-up
- tests make future regression obvious

That is the correct production-facing shape for this priority.
