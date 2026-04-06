# Priority 4 — Remove `REPLACE` from Critical Room Writes

## Purpose

Priority 4 hardens the Android scanner app’s highest-volume local write paths by removing destructive `OnConflictStrategy.REPLACE` semantics from attendee persistence and sync metadata persistence, while preserving the current progressive sync runtime.

This is a correctness and safety refactor, not a product-surface feature. It should be done **after** the operator-facing priorities are already moving, not before them.

---

## Why this Priority Exists

`ScannerDao` still uses `OnConflictStrategy.REPLACE` for:

- attendee persistence
- replay cache persistence
- replay suppression persistence
- latest flush snapshot persistence
- recent flush outcome persistence
- sync metadata persistence

The highest operational risk is the attendee sync path and the sync metadata path.

For attendee sync, `REPLACE` is blunt because it is implemented by SQLite as delete-then-insert behavior. Even when it “works,” it is the wrong semantic tool for frequently updated local truth.

For sync metadata, `REPLACE` also hides intent. This metadata marks the last fully successful sync boundary and should be updated precisely, not destructively.

This priority is therefore about:

1. replacing destructive write semantics on attendee rows
2. replacing destructive write semantics on sync metadata rows
3. locking the current paged-sync / metadata-lag behavior with regression tests
4. **not** widening into replay cache, flush snapshot, or other persistence surfaces yet

---

## Repo Grounding

This plan is based on the current repo as it exists today.

### Current facts

- `ScannerDao` uses `@Insert(onConflict = OnConflictStrategy.REPLACE)` for both `upsertAttendees(...)` and `upsertSyncMetadata(...)`.
- `CurrentPhoenixSyncRepository` already performs **progressive page writes**: attendees are written page-by-page, then sync metadata is written only after the full paged sync completes.
- Existing tests already lock an important runtime truth:
  - attendee rows may be ahead of sync metadata after a failed later page
  - metadata must remain at the last fully successful sync boundary
- The app is already on Room `2.8.4`, so `@Upsert` is available if it keeps the code clear and small.
- No schema change is required to remove `REPLACE` semantics if Codex keeps this priority confined to DAO conflict behavior and repository/test changes.

### Files this priority is rooted in

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`
- `android/scanner-app/app/build.gradle.kts`

### Important existing runtime truths to preserve

1. **Progressive sync stays page-at-a-time.**  
   Do not revert to “collect all attendees then write once.”

2. **Attendee writes can be ahead of sync metadata.**  
   This is already an intentional property of the current progressive sync approach.

3. **Sync metadata marks the last fully successful sync boundary.**  
   Do not update metadata earlier just because a page was written successfully.

4. **This priority does not require a migration if no schema changes are introduced.**  
   If Codex proposes a migration here, that is a smell unless they can justify a real schema need.

---

## What Success Looks Like

At the end of Priority 4:

- attendee persistence no longer relies on `REPLACE`
- sync metadata persistence no longer relies on `REPLACE`
- paged sync still writes attendees progressively
- sync metadata still only advances after a fully successful sync
- current failure semantics are preserved:
  - earlier successful pages remain persisted
  - metadata does not falsely advance after a later failure
- tests explicitly lock these guarantees
- replay cache / flush snapshot / other `REPLACE` usage remains untouched for now

---

## Scope Boundaries

## In scope

- attendee DAO write semantics
- sync metadata DAO write semantics
- `CurrentPhoenixSyncRepository` adjustments needed to use the new DAO shape cleanly
- DAO and repository tests for correctness and regression protection

## Out of scope

- replay cache write semantics
- flush snapshot write semantics
- recent flush outcomes write semantics
- replay suppression write semantics
- queue persistence redesign
- search / support / diagnostics / event UI changes
- schema changes unless truly unavoidable

---

## Architecture and Truth Rules

1. Do not change the sync API contract.
2. Do not change the progressive sync algorithm shape.
3. Do not introduce any collect-all-pages-in-memory design.
4. Do not “simplify” by making attendee + metadata always atomic across the whole paged sync.
5. Do not widen into other `REPLACE` users in `ScannerDao`.
6. Prefer the smallest precise Room API that expresses the real write intent.
7. Keep code readable and boring.

---

## Recommended PR Split

Use **three PRs**.

This keeps the refactor small, reviewable, and honest.

### PR 4A — Attendee write semantics
- **Branch:** `codex/priority4-attendee-upsert`
- **PR title:** `[codex] priority 4 attendee upsert semantics`

### PR 4B — Sync metadata write semantics
- **Branch:** `codex/priority4-sync-metadata-write-integrity`
- **PR title:** `[codex] priority 4 sync metadata write integrity`

### PR 4C — Progressive sync regression lock
- **Branch:** `codex/priority4-progressive-sync-regressions`
- **PR title:** `[codex] priority 4 progressive sync regression lock`

### Example worktree commands

```bash
git fetch origin

git worktree add ../fastcheck-priority4a -b codex/priority4-attendee-upsert origin/main
git worktree add ../fastcheck-priority4b -b codex/priority4-sync-metadata-write-integrity origin/main
git worktree add ../fastcheck-priority4c -b codex/priority4-progressive-sync-regressions origin/main
```

---

# PR 4A — Attendee Write Semantics

## Goal

Replace destructive attendee `REPLACE` semantics with proper upsert behavior while preserving the current paged sync flow.

## Why this PR comes first

This is the highest-volume write path and the cleanest place to remove destructive semantics first.

If Codex touches attendee and metadata writes in one PR, review gets muddy.

## Files to touch

### Primary
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`

### Tests
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

## Implementation intent

Codex should replace attendee `REPLACE` with one of these two approaches:

### Preferred
Use `@Upsert` for attendee rows **if** it keeps the DAO minimal and clear.

### Acceptable fallback
Use explicit insert/update semantics if `@Upsert` becomes awkward.

Examples of acceptable fallback patterns:
- insert-ignore + update
- update-first + insert-missing
- a narrow transaction helper if needed

### Not acceptable
- leaving `REPLACE` in place
- deleting rows manually and reinserting them
- redesigning the sync algorithm
- changing how pages are fetched or buffered

## Detailed implementation notes

- Keep the existing `upsertAttendees(...)` entrypoint name if that keeps repo churn low.
- If a new DAO method name is clearer, change it carefully and update the repository/tests cleanly.
- Do not change `CurrentPhoenixSyncRepository` behavior beyond what is needed to call the new attendee write path.
- Do not touch metadata semantics in this PR unless absolutely required for compilation.

## Edge cases to protect

- repeated sync of the same attendee ID with changed fields
- repeated sync of same `(eventId, ticketCode)` identity
- attendee with updated name/email/payment/inside state
- page 1 succeeds, later page fails
- canonicalized ticket code still remains the lookup key

## Acceptance criteria

- no attendee write path uses `REPLACE`
- current paged sync tests still pass
- repeated attendee sync updates fields correctly
- no change to sync API behavior
- no schema migration added

## Copy-paste Codex prompt — PR 4A

| Field | Content |
|---|---|
| Task | Replace destructive `REPLACE` semantics for attendee persistence with proper upsert behavior in the Android scanner app. |
| Objective | Remove delete-then-insert behavior from the highest-volume local write path while preserving the current paged sync model. |
| Output | Update `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt` and any minimal call sites in `data/repository/CurrentPhoenixSyncRepository.kt`; add or update focused DAO/repository tests. |
| Note | Prefer `@Upsert` on Room 2.8.4 if it stays clean. Otherwise use explicit insert/update semantics. Preserve page-at-a-time attendee writes. Do not reintroduce heap-heavy “collect all attendees then write once.” Do not widen into sync metadata, replay cache, or flush snapshot semantics in this PR. No schema migration unless truly required. |

---

# PR 4B — Sync Metadata Write Integrity

## Goal

Replace `REPLACE` semantics for sync metadata with precise update/upsert behavior while preserving current sync boundary truth.

## Why this PR is separate

Metadata is not just “another row.” It represents the last fully successful sync boundary.

That makes it a separate semantic concern from attendee row persistence.

## Files to touch

### Primary
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`

### Tests
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

## Implementation intent

Codex should replace metadata `REPLACE` with a precise insert/update or `@Upsert` path that expresses:

- metadata for an event is created if missing
- metadata for an event is updated precisely if present
- metadata is still only written after a fully successful sync

## Important truth to preserve

This repo already allows attendee rows to get ahead of metadata during a failed paged sync.

That is not a bug to “fix” here. That is part of the current progressive sync model.

Do not change that.

## Detailed implementation notes

- Keep `loadSyncMetadata(eventId)` behavior unchanged.
- Keep `observeLatestSyncMetadata()` behavior unchanged unless a DAO signature change truly requires it.
- Keep `CurrentPhoenixSyncRepository.syncAttendees()` shape intact:
  - fetch pages
  - persist each page
  - only after the full sync succeeds, persist metadata
- Do not bundle attendee writes and metadata writes into one global transaction for the whole paged sync.

## Edge cases to protect

- event metadata insert when missing
- metadata update when present
- failure after attendees were persisted but before metadata write
- failure during metadata write leaves previous metadata intact
- incremental sync preserves watermark semantics

## Acceptance criteria

- no metadata write path uses `REPLACE`
- metadata still only advances after a fully successful sync
- attendee-ahead-of-metadata behavior remains intact on late failure
- no sync algorithm rewrite
- no schema migration added

## Copy-paste Codex prompt — PR 4B

| Field | Content |
|---|---|
| Task | Replace `REPLACE` semantics for sync metadata with precise update/upsert behavior and preserve the current paged-sync boundary semantics. |
| Objective | Keep sync metadata truthful as the last fully successful sync boundary without destructive delete-then-insert writes. |
| Output | Update `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`, `data/repository/CurrentPhoenixSyncRepository.kt`, and focused DAO/repository tests. |
| Note | Preserve the current model where attendee rows may be ahead of sync metadata after a failed later page. Do not atomically wrap the whole paged sync into one giant transaction. Metadata must still advance only after the full sync succeeds. Prefer the smallest clean DAO shape. No unrelated persistence refactors. |

---

# PR 4C — Progressive Sync Regression Lock

## Goal

Turn the current subtle sync guarantees into explicit regression protection so future refactors do not quietly reintroduce destructive behavior or change sync boundary truth.

## Why this PR should exist

The repo already has strong sync tests, but this priority is easy to “complete” with a DAO annotation swap and too little protection.

This PR makes the guarantees obvious and reviewable.

## Files to touch

### Tests only, ideally
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepositoryTest.kt`

### Optional small comment/docs touch
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`

## What to lock explicitly

Add or tighten tests for:

1. repeated attendee updates do not require destructive replace semantics
2. page-at-a-time persistence still works
3. earlier successful pages survive later-page failure
4. metadata remains at prior successful sync boundary on failure
5. metadata write failure does not wipe earlier attendee writes
6. current ordering assumptions for latest sync metadata remain documented and tested where realistic

## What not to do

- do not add broad instrumentation churn just for this priority
- do not add screenshot/UI tests
- do not widen into migration tests unless Codex introduced a schema change
- do not touch replay cache / flush snapshot write semantics here

## Acceptance criteria

- tests clearly communicate the intended sync semantics
- future destructive write reintroductions are harder to slip in
- no UI changes
- no database version bump unless a real schema change happened earlier

## Copy-paste Codex prompt — PR 4C

| Field | Content |
|---|---|
| Task | Add regression tests that lock the current paged-sync and precise write semantics after the attendee and sync metadata refactors. |
| Objective | Prevent future regressions that reintroduce destructive `REPLACE` behavior or blur the sync boundary truth. |
| Output | Expanded tests in `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt` and `data/repository/CurrentPhoenixSyncRepositoryTest.kt`, plus only minimal comments if they materially improve clarity. |
| Note | Lock repeated attendee updates, partial page persistence, metadata lag on failed later pages, and metadata write failure behavior. Keep this PR test-focused. Do not widen into replay cache, flush snapshot, or UI work. No schema migration unless earlier PRs forced one. |

---

## Risks, Failure Modes, and Review Traps

### Main failure modes

1. **Codex swaps `REPLACE` to `@Upsert` without checking semantic fallout**  
   This is only acceptable if tests prove behavior is preserved.

2. **Codex “fixes” attendee-ahead-of-metadata behavior**  
   That would be a semantic rewrite, not this priority.

3. **Codex wraps the whole paged sync in one transaction**  
   That would undo the current progressive persistence design.

4. **Codex widens into replay cache / flush snapshot semantics**  
   Out of scope.

5. **Codex introduces a migration with no schema need**  
   That is unnecessary churn.

### Review questions to ask on every PR

- Did this remove `REPLACE` from the targeted path?
- Did this preserve page-at-a-time writes?
- Did this preserve the metadata boundary semantics?
- Did this avoid widening into unrelated persistence paths?
- Did this avoid a schema change unless truly necessary?

---

## Merge Order

Merge in this order:

1. **PR 4A — attendee upsert semantics**
2. **PR 4B — sync metadata write integrity**
3. **PR 4C — progressive sync regression lock**

Do not invert this order.

If Codex starts with “tests only,” the review will stay too abstract.
If Codex combines 4A and 4B, the semantic review gets harder than it needs to be.

---

## Validation Commands

Use these on every PR:

```bash
git diff --check

JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 \
bash ./gradlew \
  -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 \
  :app:compileDebugKotlin \
  :app:testDebugUnitTest
```

If Codex introduces any schema change anyway, also require migration/instrumentation validation before merge.

---

## What to Reject from Codex

Push back if Codex:

- leaves `REPLACE` on attendee or sync metadata writes
- rewrites the whole sync algorithm
- buffers all sync pages in memory before writing
- “fixes” attendee-ahead-of-metadata behavior
- adds replay cache / flush snapshot refactors to the same PR
- adds a database version bump without a real schema change
- introduces broad app-wide persistence cleanup under this priority

---

## End Goal Summary

Priority 4 succeeds when the Android scanner app’s attendee sync path and sync metadata path stop relying on destructive `REPLACE` semantics **without** changing the current progressive sync runtime.

That means:

- more precise DAO intent
- safer local writes
- preserved paged sync behavior
- preserved sync boundary truth
- stronger regression protection

Nothing more. Nothing less.
