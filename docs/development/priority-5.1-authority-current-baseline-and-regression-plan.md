# Priority 5 — Current Baseline and Regression Plan

**Status:** Rebased execution plan for current `main`  
**Scope:** `android/scanner-app/` only  
**Priority Type:** Runtime retention, session-boundary safety, and DB-at-rest decisioning  
**Purpose:** Make Android scanner runtime data lifecycle explicit and testable, starting from the fact that part of the cross-event safety work already landed on `main`.

---

## 1. Why this priority still exists

Priority 5 is still real, but it is **no longer starting from zero**.

Two important things are already true on `main`:

1. **JWT storage is already encrypted** via `EncryptedPrefsSessionVault`.
2. **Cross-event unresolved-state blocking already exists** in the session/login path.

What is **not** done yet is the actual runtime retention policy below that session boundary.

Right now the repo can already stop obviously unsafe cross-event session use, but logout/auth-expiry/session cleanup still behaves too bluntly:

- `CurrentPhoenixSessionRepository.logout()` still only clears the token and session metadata.
- There is still no dedicated local runtime data cleaner.
- There is still no explicit retention contract for what happens to:
  - attendee cache
  - sync metadata
  - replay suppression
  - replay cache
  - latest flush snapshot
  - recent flush outcomes
  - queued scans
  - local admission overlays
- DB-at-rest encryption for Room is still a **decision gap**, not an implemented policy.

That is the real remaining scope for Priority 5.

---

## 2. Repo grounding this plan assumes

This document is based on the **current `main` branch**, not the earlier pre-local-admission planning baseline.

### Confirmed current state

- JWT storage is already encrypted in `EncryptedPrefsSessionVault`.
- Session metadata is stored separately via `SessionMetadataStore`.
- `CurrentPhoenixSessionRepository.login(...)` already blocks cross-event login when unresolved local state exists for another event.
- `SessionGateViewModel.refreshSessionRoute()` already blocks restored authenticated routes when unresolved local state exists for another event and forces the app back to logged-out with a blocking message.
- `CurrentPhoenixSessionRepository.logout()` still only clears the secure token and DataStore session metadata.
- `ScannerDao.loadUnresolvedEventIdsExcluding(...)` already treats both:
  - unreplayed queued scans, and
  - active local admission overlays
  as unresolved local gate state.
- `auth_model.md` already states that `401` auth-expired leaves queued scans in Room and requires manual re-login.
- `local_persistence.md` is now partially stale because Room also contains local admission overlays, latest flush snapshot, recent flush outcomes, and replay suppression/runtime truth not described there.
- Room DB-at-rest encryption is still not implemented; no SQLCipher/Room encryption dependency or custom encrypted Room helper exists in the Android build.

### Existing files this priority must respect

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/UnresolvedAdmissionStateGate.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/security/EncryptedPrefsSessionVault.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/datastore/SessionMetadataStore.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/docs/auth_model.md`
- `android/scanner-app/docs/local_persistence.md`
- `android/scanner-app/app/build.gradle.kts`

### Existing tests this priority should extend

- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepositoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`

---

## 3. What changed since the old Priority 5 plan

The original Priority 5 plan assumed cross-event queue safety was still entirely future work.

That is no longer true.

### Already moved forward on `main`

- unresolved cross-event queue/overlay detection exists in DAO
- unresolved-state blocking exists in login flow
- unresolved-state blocking exists in restored-session gating

### Still missing

- explicit retention contract in docs and code-level naming
- dedicated runtime data cleaner
- session-boundary cleanup wiring that differentiates:
  - explicit logout
  - auth expiry
  - same-event re-login
  - different-event transition
- cleanup methods in DAO for non-durable runtime state
- DB encryption ADR / decision record

So this new plan starts from:

**“cross-event guard exists, but runtime lifecycle is still accidental.”**

---

## 4. Non-negotiable runtime rules

These rules are not optional. Every PR in this priority must preserve them.

### Rule 1
**Queued scans are durable operational truth.**  
They must not be silently discarded.

### Rule 2
**Explicit logout and auth expiry are not the same transition.**  
They may clear different runtime surfaces.

### Rule 3
**Cross-event unresolved-state blocking already exists and must not regress.**

### Rule 4
**Retention policy belongs below UI.**  
Compose screens must not own cleanup behavior.

### Rule 5
**Session secret storage is already solved separately.**  
Do not waste this priority rebuilding JWT security that already exists.

### Rule 6
**Room encryption is a separate deliberate decision.**  
Do not mix it into retention wiring casually.

### Rule 7
**Local admission overlays are part of runtime retention now.**  
Any cleanup plan that ignores overlays is stale and wrong.

---

## 5. Updated retention matrix

This is the runtime contract Codex should implement.

## 5.1 Explicit logout

Recommended behavior:

- clear JWT from `SessionVault`
- clear session metadata from `SessionMetadataStore`
- preserve `queued_scans`
- preserve `local_admission_overlays`
- clear `attendees`
- clear `sync_metadata`
- clear `local_replay_suppression`
- clear `scan_replay_cache`
- clear `latest_flush_snapshot`
- clear `recent_flush_outcomes`

### Why
Explicit logout is an intentional operator/session handoff.
Queued scans and unresolved overlays still represent durable field work and must not be lost.
But attendee cache and session-scoped status surfaces should not bleed into the next operator session.

## 5.2 Auth expiry

Recommended behavior:

- clear JWT from `SessionVault`
- clear session metadata from `SessionMetadataStore`
- preserve `queued_scans`
- preserve `local_admission_overlays`
- preserve `attendees`
- preserve `sync_metadata`
- preserve latest flush state and recent outcomes if helpful for same-event recovery
- clear `local_replay_suppression`

### Why
Auth expiry is a recoverable interruption, not a deliberate operator handoff.
Preserving attendee cache and sync metadata helps same-event re-login recover faster.
Replay suppression is short-lived operational noise and should not survive auth churn.

## 5.3 Same-event re-login

Recommended behavior:

- allow it
- preserve all retained same-event runtime data
- do not wipe attendee cache
- do not wipe sync metadata
- do not wipe queue
- do not wipe overlays

### Why
Same-event re-login should be the fastest recovery path.

## 5.4 Different-event login, no unresolved state for the old event

Recommended behavior:

- allow it
- clear prior event attendee cache
- clear prior event sync metadata
- clear prior event replay suppression
- clear replay cache / latest flush snapshot / recent outcomes if they no longer match the active event context
- keep only durable state that is still valid and safe

### Why
This is a clean event transition only if unresolved local gate state does not exist for the previous event.

## 5.5 Different-event login with unresolved state for another event

Recommended behavior:

- block login
- preserve old queue and overlays
- surface a clear operator-facing error
- do not auto-discard
- do not auto-upload under the new event token

### Why
This guard already exists and must remain hard. The current upload path remains event-scoped and unsafe for silent cross-event reuse.

## 5.6 Crash / restart / process death

Recommended behavior:

- preserve Room runtime data
- preserve stored token/session according to existing session storage rules
- do not run cleanup on restart alone

### Why
Crash recovery should maximize durability, not surprise the operator.

---

## 6. What success looks like now

Priority 5 is complete when:

- retention behavior is explicit in docs and code-level naming
- explicit logout and auth expiry no longer behave identically by accident
- the repo has one cleaner service for non-secret runtime data cleanup
- cleanup is wired at the session boundary, not in UI
- existing cross-event unresolved-state blocking remains intact
- the remaining DB-at-rest decision is documented clearly
- regression tests make it hard to silently reintroduce accidental cleanup or silent data loss

---

## 7. Exact PR split

Implement this priority in **four PRs**.

Do not collapse these into one or two giant PRs.

| PR | Branch | PR Title | Depends On | Purpose |
|---|---|---|---|---|
| PR 1 | `codex/p5-retention-contract-baseline` | `[codex] p5 retention contract baseline` | `main` | Rebaseline docs and code-level policy naming for runtime transitions. |
| PR 2 | `codex/p5-runtime-data-cleaner` | `[codex] p5 runtime data cleaner` | PR 1 | Add DAO cleanup helpers and a single cleaner service. |
| PR 3 | `codex/p5-session-cleanup-wiring` | `[codex] p5 session cleanup wiring` | PR 2 | Wire explicit logout vs auth-expiry cleanup into the session boundary without regressing the existing cross-event guard. |
| PR 4 | `codex/p5-db-encryption-decision` | `[codex] p5 db encryption decision` | PR 3 | Add ADR/decision record for DB-at-rest encryption and implement only if explicitly approved. |

---

## 8. Worktree setup

```bash
git fetch origin
git worktree add ../fastcheck-p5-pr1 -b codex/p5-retention-contract-baseline origin/main
git worktree add ../fastcheck-p5-pr2 -b codex/p5-runtime-data-cleaner origin/main
git worktree add ../fastcheck-p5-pr3 -b codex/p5-session-cleanup-wiring origin/main
git worktree add ../fastcheck-p5-pr4 -b codex/p5-db-encryption-decision origin/main
```

Use normal stacked flow:

- PR 1 from `main`
- PR 2 from PR 1 branch tip
- PR 3 from PR 2 branch tip
- PR 4 from PR 3 branch tip

---

## 9. Recommended folder and file additions

```text
android/scanner-app/
  docs/
    runtime_data_retention_policy.md
    db_at_rest_encryption_decision.md

  app/src/main/java/za/co/voelgoed/fastcheck/
    data/repository/
      LocalRuntimeTransition.kt
      LocalRuntimeDataCleaner.kt
      DefaultLocalRuntimeDataCleaner.kt
      RuntimeDataRetentionPolicy.kt
```

### Why this structure

- keeps lifecycle and retention logic in repository/data boundary code, not UI
- makes policy naming explicit
- gives the repo one obvious home for cleanup behavior
- keeps DB encryption as a separate doc-driven decision

---

# 10. PR 1 — Retention contract baseline

## 10.1 Goal

Document and codify the current runtime retention contract, starting from what is already true on `main`.

## 10.2 Why this PR comes first

Because this priority should not begin with deletes, cleaners, or logout rewiring.
The contract has to be explicit first.

## 10.3 Scope

### Create

- `android/scanner-app/docs/runtime_data_retention_policy.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeTransition.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/RuntimeDataRetentionPolicy.kt`

### Update

- `android/scanner-app/docs/local_persistence.md`
- `android/scanner-app/docs/auth_model.md`

## 10.4 Exact implementation requirements

### runtime_data_retention_policy.md
Must explicitly define behavior for:

- explicit logout
- auth expiry
- same-event re-login
- different-event transition with no unresolved state
- different-event transition with unresolved state
- crash/restart

### local_persistence.md
Update to reflect current reality:

- Room now includes local admission overlays, latest flush snapshot, recent outcomes, and replay suppression/runtime truth beyond the old abbreviated list
- queued scans and overlays are durable local operational truth
- not all runtime state is equally durable

### auth_model.md
Update wording so it matches the new lifecycle contract:
- `401` retains queue and overlays
- re-login is required
- explicit logout has different cleanup semantics than auth expiry

### Code-level policy types
Keep them minimal and explicit.

Recommended:
- `enum class LocalRuntimeTransition`
- `data class RuntimeDataRetentionPolicy(...)` or equivalent narrow policy/value holder

Do not build a strategy-pattern framework here.

## 10.5 Constraints

- no cleaner implementation yet
- no session wiring yet
- no database changes
- no UI changes

## 10.6 Acceptance criteria

- repo docs explicitly describe runtime retention behavior
- docs no longer imply Room is just attendees/queue/replay/sync metadata
- naming is settled before cleanup implementation begins

## 10.7 Tests

Optional tiny policy unit tests only if code-level transition/policy helpers are added.
This PR is primarily docs + naming.

## 10.8 Out of scope

- actual cleanup
- DAO delete methods
- logout/auth wiring
- DB encryption implementation

## 10.9 TOON prompt — PR 1

| Field | Content |
|---|---|
| Task | Define the explicit runtime data retention contract for the Android scanner app based on current `main`, including the cross-event guard that already exists. |
| Objective | Replace accidental lifecycle behavior with a documented and code-named retention policy before cleanup wiring begins. |
| Output | Create `docs/runtime_data_retention_policy.md`, `data/repository/LocalRuntimeTransition.kt`, and `data/repository/RuntimeDataRetentionPolicy.kt`; update `docs/local_persistence.md` and `docs/auth_model.md`. |
| Note | JWT storage is already encrypted; do not rebuild that. Cross-event unresolved-state blocking already exists on `main`; preserve and document it. This PR is docs + naming only. No cleanup logic, no session rewiring, no DB changes. Keep names explicit and minimal. |

---

# 11. PR 2 — Runtime data cleaner

## 11.1 Goal

Add one local runtime data cleaner service and the DAO cleanup helpers it needs.

## 11.2 Why this PR comes second

Because once the retention contract exists, the repo needs one place below UI to apply it safely.

## 11.3 Scope

### Create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeDataCleaner.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/DefaultLocalRuntimeDataCleaner.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeDataCleanerTest.kt`

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/di/RepositoryModule.kt` if binding is needed

## 11.4 DAO methods to add

Recommended additions:

- `deleteAllAttendees()`
- `deleteAttendeesForEvent(eventId: Long)`
- `deleteAllSyncMetadata()`
- `deleteSyncMetadataForEvent(eventId: Long)`
- `clearReplaySuppression()`
- `clearReplayCache()`
- `clearLatestFlushSnapshot()`
- `clearRecentFlushOutcomes()`
- `deleteOverlaysForEvent(eventId: Long)` only if policy requires event-scoped cleanup in cleaner paths
- helper inspection methods if still missing for policy evaluation

Do not add queue deletion by default.
Do not add blanket “clear everything” methods without intent-specific wrappers.

## 11.5 Cleaner responsibilities

Expose intent-level methods, for example:

- `handleExplicitLogout(currentEventId: Long?)`
- `handleAuthExpired(currentEventId: Long?)`
- `handleCleanEventTransition(fromEventId: Long?, toEventId: Long)`
- `canTransitionToEvent(targetEventId: Long): Boolean` only if you need cleaner-level helper logic in addition to the existing gate

The cleaner must preserve queue and overlays by default for logout/auth-expiry paths.

## 11.6 Constraints

- no session wiring yet
- no UI wiring
- no DB schema change unless truly unavoidable
- no DB encryption work

## 11.7 Acceptance criteria

- cleaner logic is explicit and idempotent
- queue and overlays remain preserved by default
- non-durable runtime state can be cleared below UI
- cleanup helpers are testable in isolation

## 11.8 Tests

### ScannerDaoTest additions
Must cover:
- attendees can be cleared
- sync metadata can be cleared
- replay suppression can be cleared
- replay cache / flush snapshot / recent outcomes can be cleared
- queue rows remain untouched by cleanup helpers that are not supposed to touch them
- overlays remain untouched unless an explicit event-scoped delete path is intentionally called

### LocalRuntimeDataCleanerTest
Must cover:
- explicit logout cleanup behavior
- auth-expiry cleanup behavior
- same-event no-op / preserve path
- clean event transition path
- queue and overlays preserved where policy says so

## 11.9 Out of scope

- wiring into login/logout/session flows
- changes to unresolved-state guard behavior
- DB encryption ADR

## 11.10 TOON prompt — PR 2

| Field | Content |
|---|---|
| Task | Implement a local runtime data cleaner and the DAO cleanup helpers it needs without wiring it into session flows yet. |
| Objective | Centralize runtime retention behavior below UI and make later session-boundary wiring safe and testable. |
| Output | Create `LocalRuntimeDataCleaner.kt` and `DefaultLocalRuntimeDataCleaner.kt`; update `ScannerDao.kt`; add focused DAO and cleaner tests. |
| Note | Preserve queued scans and local admission overlays by default. Add explicit cleanup only for attendee cache, sync metadata, replay suppression, replay cache, latest flush snapshot, and recent flush outcomes. Do not wire this into session/login/logout yet. No schema change unless unavoidable. Keep the cleaner boring and intention-level. |

---

# 12. PR 3 — Session cleanup wiring

## 12.1 Goal

Wire explicit logout vs auth-expiry cleanup into the session boundary without regressing the existing cross-event unresolved-state guard.

## 12.2 Why this PR comes third

Because the cleaner has to exist before session code can use it safely.

## 12.3 Scope

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepositoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt`

### Optional
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModelTest.kt` if login error wording needs explicit coverage

## 12.4 Exact implementation requirements

### CurrentPhoenixSessionRepository.logout()
Change from:
- clear token
- clear metadata

To:
- clear token
- clear metadata
- invoke cleaner explicit-logout path

### SessionGateViewModel.refreshSessionRoute()
Expired-session handling currently uses `sessionRepository.logout()` through the logged-out path.
This priority must stop treating auth expiry as identical to explicit logout.

Preferred approach:
- add an auth-expiry-specific cleanup path through the session boundary
- preserve queue and overlays
- preserve attendee cache and sync metadata for same-event recovery
- still route to logged-out/login gate

Do not solve this with UI-only flags.

### Cross-event unresolved-state blocking
Do not remove it.
Do not weaken it.
If cleanup refactors move method names around, preserve the hard block.

### Same-event re-login
Must remain fast:
- preserved queue
- preserved overlays
- preserved attendee cache
- preserved sync metadata

## 12.5 Constraints

- no queue discard path
- no auto-resolve of foreign event state
- no UI-owned cleanup
- no DB encryption work

## 12.6 Acceptance criteria

- explicit logout and auth expiry no longer share identical cleanup semantics by accident
- existing cross-event unresolved-state blocking still works
- same-event re-login remains smooth
- login/session tests cover the changed behavior

## 12.7 Tests

### CurrentPhoenixSessionRepositoryTest
Add or update tests for:
- explicit logout clears token/metadata and runs explicit-logout cleanup
- login guard still blocks cross-event unresolved state
- same-event login remains allowed when no conflicting unresolved other-event state exists

### SessionGateViewModelTest
Add or update tests for:
- expired-session route uses auth-expiry cleanup semantics, not plain explicit-logout semantics
- unresolved other-event state still blocks restored authenticated route
- logout still routes to logged out cleanly

### Optional auth/login tests
If needed, cover that blocking messages/errors remain operator-facing and truthful.

## 12.8 Out of scope

- DB encryption
- queue/archive/discard tooling
- large auth redesign
- token refresh

## 12.9 TOON prompt — PR 3

| Field | Content |
|---|---|
| Task | Wire explicit logout and auth-expiry cleanup into the session boundary while preserving the cross-event unresolved-state guard already on `main`. |
| Objective | Make runtime cleanup semantics intentional at the real session boundary instead of treating all logged-out transitions the same. |
| Output | Update `CurrentPhoenixSessionRepository.kt`, `SessionGateViewModel.kt`, and session/login tests. |
| Note | Do not regress the existing hard block for unresolved other-event queue/overlay state. Preserve queued scans and overlays by default. Auth expiry must preserve same-event attendee cache and sync metadata. Keep cleanup below UI. No queue discard/archive flow. No auth refresh subsystem. |

---

# 13. PR 4 — DB-at-rest encryption decision

## 13.1 Goal

Record the DB-at-rest encryption decision explicitly and implement it only if deployment policy really requires it.

## 13.2 Why this PR comes last

Because retention behavior must be explicit first.
Encryption without lifecycle clarity is premature and risky.

## 13.3 Scope

### Create

- `android/scanner-app/docs/db_at_rest_encryption_decision.md`

### Optional later implementation only if approved

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/di/DatabaseModule.kt`
- any encrypted Room integration files
- migration/startup tests if implementation is approved

## 13.4 ADR must answer

- what sensitive data is already protected outside Room
- what still lives in plain Room
- what operational risk remains if a device is lost
- what migration risk DB encryption introduces
- whether offline upgrade failure could threaten queue durability
- whether support/ops burden outweighs benefit for current rollout stage

## 13.5 Constraints

- do not implement encryption casually
- do not mix encryption into cleaner/session PRs
- if implementation is required, it needs its own migration plan and tests

## 13.6 Acceptance criteria

- encryption decision is explicit
- repo no longer “implicitly” postpones the decision
- implementation only happens if policy says so

## 13.7 Tests

Doc-only minimum unless encryption implementation is explicitly approved.
If approved later:
- startup-open tests
- migration tests
- queue-durability validation across upgrade path

## 13.8 TOON prompt — PR 4

| Field | Content |
|---|---|
| Task | Produce the DB-at-rest encryption decision record for the Android scanner runtime and implement encrypted Room only if policy explicitly requires it. |
| Objective | Make Room encryption a deliberate security and migration decision after retention behavior is explicit and tested. |
| Output | Create `docs/db_at_rest_encryption_decision.md` and, only if approved, a narrowly scoped implementation plan or code changes. |
| Note | JWT storage is already encrypted outside Room. Focus on what remains in plain Room, migration/upgrade risk, queue durability, and support burden. Do not mix this with retention-policy implementation unless explicitly approved. |

---

## 14. Validation commands for every PR

Run after each PR slice.

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

If PR 4 implements Room encryption later, require dedicated migration/startup validation before merge.

---

## 15. What Codex must not do

Reject the PR if Codex does any of this:

- wipes `queued_scans` by default during logout
- wipes `local_admission_overlays` by default during logout/auth expiry without policy approval
- treats auth expiry as identical to explicit logout without justification
- weakens the existing cross-event unresolved-state guard
- moves cleanup behavior into Compose/UI code
- starts Room encryption work before the ADR/decision is merged
- broadens this into queue redesign or sync redesign
- invents token refresh as part of this priority

---

## 16. What success looks like

Priority 5 succeeds when:

- runtime retention behavior is explicit and documented
- queue durability is preserved intentionally
- overlays are treated as first-class retained runtime truth
- explicit logout, auth expiry, and event transition no longer behave the same by accident
- existing cross-event unresolved-state blocking remains intact
- cleanup lives in a dedicated repository-boundary cleaner
- DB-at-rest encryption is either deliberately approved with a migration plan or deliberately postponed with recorded reasons

That is the correct production-facing shape for this priority.
