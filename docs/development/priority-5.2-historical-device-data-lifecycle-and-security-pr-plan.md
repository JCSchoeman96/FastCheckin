# Priority 5 — Device Data Lifecycle and Security

## Goal

Make local runtime data persistence explicit, predictable, and safe.

This priority is **not** primarily about JWT handling. The repo already stores the JWT in an encrypted session vault and keeps non-secret session metadata in DataStore. The real gap is the **Room runtime store lifecycle**: what survives logout, auth expiry, event changes, and device restarts.

This priority succeeds when the app can explain, in code and tests:

- what survives explicit logout
- what survives auth expiry
- what survives crash/restart
- what happens when the operator logs into a different event on the same device
- whether Room itself is encrypted at rest

---

## Verdict on the Base Priority

Your base priority is correct, but it needed one hard correction:

**“Preserve queue by default” is only safe if cross-event login is guarded.**

Queued scan rows carry `eventId` locally, but the outbound upload payload does **not** include `event_id`; upload is tied to the active event-scoped login token. That means preserving old queued rows and then logging into a different event can create unsafe cross-event upload behavior if the app does not explicitly block or resolve that transition.

That is the hidden risk that must drive this whole plan.

---

## Repo Grounding

### What already exists

- JWT storage is already encrypted via `EncryptedPrefsSessionVault`.
- Session metadata is already stored separately in DataStore.
- Room is already the structured store for attendee cache, queued scans, replay cache, and sync metadata.
- Current logout clears the token and session metadata only.
- Auth model already states that `401` auth-expired leaves queued scans in Room and requires manual re-login.
- `SessionGateViewModel` currently turns expired sessions into logout through the session boundary.
- `AuthViewModel` already surfaces repository login failures directly to the login UI.
- Queued scan payload mapping omits `event_id`, so event transition safety cannot be hand-waved.

### What this means

Priority 5 is not “add security everywhere.”

It is:

1. define the runtime retention contract
2. implement a cleaner that follows that contract
3. wire that cleaner into session/logout/event transitions
4. block unsafe event changes while foreign queued rows exist
5. only then decide whether DB-at-rest encryption is required

---

## Non-negotiable Rules

1. **Queued scans are durable operational truth.** They are not wiped implicitly.
2. **Explicit logout and auth expiry are not the same transition.**
3. **Cross-event login with preserved foreign queued rows is unsafe until guarded.**
4. **Retention policy belongs below UI.** The session boundary and runtime data cleaner own it, not Compose screens.
5. **DB encryption is a separate decision after retention behavior is explicit and tested.**

---

## Recommended Retention Matrix

This matrix is the contract Codex should implement.

### 1) Explicit logout

Recommended behavior:

- Clear JWT from `SessionVault`
- Clear session metadata from `SessionMetadataStore`
- Preserve `queued_scans`
- Preserve `quarantined_scans` if Priority 3 is already merged
- Clear `attendees`
- Clear `sync_metadata`
- Clear `local_replay_suppression`
- Clear `scan_replay_cache`
- Clear `latest_flush_snapshot`
- Clear `recent_flush_outcomes`

Why:

- explicit logout means the operator is finished on this device
- queued scans still represent durable field work and must not be silently lost
- attendee cache and session-scoped status surfaces should not bleed into the next operator session

### 2) Auth expiry

Recommended behavior:

- Clear JWT from `SessionVault`
- Clear session metadata from `SessionMetadataStore`
- Preserve `queued_scans`
- Preserve `quarantined_scans` if present
- Preserve `attendees`
- Preserve `sync_metadata`
- Preserve recent flush status if it helps same-event recovery
- Clear `local_replay_suppression`

Why:

- auth expiry is a recoverable interruption, not an intentional operator handoff
- preserving attendee cache and sync metadata allows a same-event re-login to recover faster
- preserving queue remains mandatory
- replay suppression is short-lived operational noise and should not span auth churn

### 3) Successful login to the same event

Recommended behavior:

- Preserve everything already retained by auth-expiry recovery
- Do not wipe attendee cache or sync metadata
- Do not wipe queue
- Reset only ephemeral UI/bootstrap state above the persistence layer if needed

Why:

- same-event re-login should be the fastest recovery path

### 4) Successful login to a different event, with **no** queued rows for the previous event

Recommended behavior:

- Allow login
- Clear prior event attendee cache and sync metadata
- Clear replay suppression, replay cache, and old flush status
- Preserve only data that remains valid and safe under the new event context

Why:

- this is a clean event transition with no admission backlog risk

### 5) Successful login to a different event, with queued rows still present for the previous event

Recommended behavior:

- **Block the event transition for now**
- Fail login with a clear operator-facing error
- Do not auto-discard old queue
- Do not auto-upload old queue under the new event token
- Do not clear old queue unless a future explicit discard/archive workflow exists

Why:

- current queued payload upload is event-token-scoped and does not include `event_id`
- silent preservation plus new-event login is unsafe
- silent discard is worse
- until explicit archive/discard tooling exists, block the switch

### 6) Crash / restart / process death

Recommended behavior:

- Preserve all Room runtime state
- Preserve session metadata/token according to current session storage rules
- Do not run cleanup just because the process restarted

Why:

- crash recovery should maximize durability, not surprise the operator

---

## Exact PR Split

## PR 5A — Retention contract and transition policy

### Branch
`codex/priority5-retention-contract`

### PR title
`[codex] priority 5 retention contract and transition policy`

### Why this PR exists

Codex should not start by deleting tables or wiring logout hooks. The contract has to be explicit first, especially around auth expiry vs logout and cross-event queue safety.

### Scope

- add the retention matrix to project docs
- define minimal code-level policy types for the runtime transitions
- define the cross-event queue guard policy in writing and code-level naming
- no DB cleaner implementation yet

### Files to create/update

Create:

- `android/scanner-app/docs/runtime_data_retention_policy.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeTransition.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/EventTransitionGuardDecision.kt`

Reference/update if needed:

- `android/scanner-app/docs/local_persistence.md`
- `android/scanner-app/docs/auth_model.md`

### Acceptance criteria

- retention behavior is explicitly documented for logout, auth expiry, same-event login, cross-event login, and restart
- cross-event login with foreign queued rows is explicitly called out as blocked behavior until an explicit discard/archive path exists
- naming is settled before implementation starts

### Copy-paste Codex prompt

| Field | Content |
|---|---|
| Task | Define the explicit runtime data retention contract and transition policy for the Android scanner app before implementing cleanup behavior. |
| Objective | Replace accidental persistence with a clear policy for logout, auth expiry, same-event re-login, cross-event login, and restart behavior. |
| Output | `android/scanner-app/docs/runtime_data_retention_policy.md` plus minimal policy types such as `LocalRuntimeTransition.kt` and `EventTransitionGuardDecision.kt` under `data/repository/`. |
| Note | Root this in the current repo truth: JWT storage is already encrypted, Room is still the main runtime store, queued scans must be preserved by default, and cross-event login with preserved foreign queued rows is unsafe because upload payloads do not include `event_id`. Do not implement cleanup in this PR. Keep it deterministic and explicit. |

---

## PR 5B — Local runtime data cleaner and DAO cleanup methods

### Branch
`codex/priority5-runtime-data-cleaner`

### PR title
`[codex] priority 5 local runtime data cleaner`

### Why this PR exists

Once the retention contract exists, the app needs a single cleaner service to apply it safely. Cleanup logic must not be scattered across UI, session, and worker code.

### Scope

- add DAO cleanup methods for non-durable runtime data
- add runtime cleaner interface + default implementation
- add queue/event inspection helpers needed for later transition guards
- do not wire into login/logout yet

### Files to create/update

Create:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeDataCleaner.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/DefaultLocalRuntimeDataCleaner.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/LocalRuntimeDataCleanerTest.kt`

Update:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/ScannerDaoTest.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/di/RepositoryModule.kt` if cleaner needs DI binding

### DAO methods to add

Recommended additions:

- `deleteAllAttendees()`
- `deleteAttendeesForEvent(eventId: Long)`
- `deleteAllSyncMetadata()`
- `deleteSyncMetadataForEvent(eventId: Long)`
- `clearReplaySuppression()`
- `clearReplayCache()`
- `clearLatestFlushSnapshot()`
- `clearRecentFlushOutcomes()`
- `replaceLatestFlushState(...)` stays as-is
- `countPendingScansForEvent(eventId: Long)`
- `loadDistinctPendingQueueEventIds()` or equivalent

If Priority 3 quarantine is already merged, add optional event-scoped quarantine inspection methods but do not couple this PR to quarantine tooling.

### Cleaner responsibilities

The cleaner should expose **intention-level** methods, not raw table deletes, for example:

- `handleExplicitLogout(currentEventId: Long?)`
- `handleAuthExpired(currentEventId: Long?)`
- `handleEventTransition(fromEventId: Long?, toEventId: Long)`
- `canTransitionToEvent(targetEventId: Long): EventTransitionGuardDecision`

### Acceptance criteria

- cleanup methods are explicit and idempotent
- queue rows are untouched by default cleanup paths
- cleaner behavior is testable without UI
- helper methods exist to detect whether preserved queued rows belong to another event

### Copy-paste Codex prompt

| Field | Content |
|---|---|
| Task | Implement a local runtime data cleaner and the DAO cleanup helpers it needs, without wiring it into session flows yet. |
| Objective | Centralize local data retention behavior and make later logout/auth-expiry/event-transition wiring safe and testable. |
| Output | `LocalRuntimeDataCleaner.kt`, `DefaultLocalRuntimeDataCleaner.kt`, DAO cleanup helpers in `ScannerDao.kt`, and focused DAO/repository tests. |
| Note | Keep queue preservation as the default. Add explicit cleanup for attendee cache, sync metadata, replay suppression, replay cache, and latest flush surfaces. Add queue inspection helpers so later event-transition guards can detect foreign queued rows. Do not wire this into login/logout in this PR. Keep schema unchanged unless absolutely necessary. |

---

## PR 5C — Session wiring and cross-event transition guard

### Branch
`codex/priority5-session-wiring-and-event-guard`

### PR title
`[codex] priority 5 session wiring and event transition guard`

### Why this PR exists

The retention contract only matters once it is enforced. This PR wires cleanup into session/logout flows and blocks unsafe event changes when foreign queue rows exist.

### Scope

- wire cleaner into `CurrentPhoenixSessionRepository.logout()`
- apply auth-expiry cleanup through the session boundary
- guard cross-event login when preserved queued rows exist for another event
- ensure same-event re-login remains fast
- surface guarded login failures via existing auth error flows

### Files to create/update

Update:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModel.kt` only if test or wording support is needed
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepositoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModelTest.kt` if login guard errors need explicit coverage

### Required behavior

#### Explicit logout
- clear token and session metadata
- run `handleExplicitLogout(...)`
- preserve queue

#### Auth expiry
- when session route resolves to logged out because the session is expired, use the auth-expiry cleanup path rather than pretending this is an ordinary explicit logout
- preserve queue
- preserve same-event attendee cache and sync metadata

#### Same-event login
- allow it
- do not clear cache/sync data unnecessarily

#### Different-event login with foreign queued rows
- reject login with a clear error message, for example:
  - `This device still has queued scans for another event. Upload or explicitly discard them before switching events.`
- do not clear queue automatically
- do not save the new session if the guard fails

#### Different-event login with no foreign queued rows
- allow login
- clean old event cache/status according to the retention contract

### Acceptance criteria

- explicit logout and auth expiry no longer share identical cleanup semantics unless the policy says they should
- same-event re-login remains operationally smooth
- foreign queued rows block unsafe event switching
- login errors surface cleanly through the existing auth UI path

### Copy-paste Codex prompt

| Field | Content |
|---|---|
| Task | Wire the runtime data cleaner into session/logout flows and add a hard guard for unsafe cross-event login when queued rows for another event still exist. |
| Objective | Enforce the retention contract at the real session boundary and stop preserved queue data from becoming cross-event upload risk. |
| Output | Updates to `CurrentPhoenixSessionRepository.kt`, `SessionGateViewModel.kt`, and any required login-flow tests, plus repository/session/auth tests for transition behavior. |
| Note | Preserve queued scans by default. Treat auth expiry differently from explicit logout. Same-event re-login should stay fast. If foreign queued rows exist, block login to a different event and return a clear operator-facing error; do not auto-discard and do not allow new-event token use over old queued rows. Keep this logic in the session/repository boundary, not Compose UI. |

---

## PR 5D — DB-at-rest encryption ADR and optional implementation gate

### Branch
`codex/priority5-db-encryption-adr`

### PR title
`[codex] priority 5 db at rest encryption decision`

### Why this PR exists

After retention behavior is explicit and tested, the team can decide whether Room database encryption is required for deployment. This must be treated as a deliberate migration and support decision, not a reflex.

### Scope

- produce a small ADR-style document
- evaluate whether current security posture is sufficient for pilot/pre-production
- only implement DB encryption if deployment policy explicitly requires it
- if implementation is required, include migration, upgrade, and rollback plan

### Files to create/update

Create:

- `android/scanner-app/docs/db_at_rest_encryption_decision.md`

Optional later implementation only if required:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/di/DatabaseModule.kt`
- any Room/open-helper integration files
- migration/support tests

### ADR must answer

- what sensitive data is already protected outside Room
- what sensitive data still sits in plain Room
- what operational risk exists if the device is lost while logged out or expired
- what migration risk DB encryption introduces
- whether offline upgrade failures could jeopardize queue durability
- whether support burden outweighs the security gain for current rollout stage

### Acceptance criteria

- encryption decision is explicit
- implementation is not mixed into retention-policy work unless clearly approved
- queue durability and upgrade safety are treated as first-class concerns

### Copy-paste Codex prompt

| Field | Content |
|---|---|
| Task | Produce the DB-at-rest encryption decision record for the Android scanner runtime and implement Room encryption only if policy explicitly requires it. |
| Objective | Make DB encryption a deliberate security and migration decision after lifecycle behavior is explicit and tested. |
| Output | `android/scanner-app/docs/db_at_rest_encryption_decision.md` and, only if required, a clearly scoped implementation plan or code changes for encrypted Room. |
| Note | JWT is already stored securely outside Room. Focus on what still remains in plain Room, the operational risk of lost devices, migration complexity, offline upgrade behavior, and queue durability. Do not mix this with retention-policy implementation unless explicitly approved. |

---

## Test Strategy

### Must-have tests

#### PR 5A
- doc/policy review only
- optional tiny policy-unit tests if code enums or decisions are added

#### PR 5B
- `ScannerDaoTest` coverage for new cleanup helpers
- `LocalRuntimeDataCleanerTest` for:
  - explicit logout cleanup
  - auth-expiry cleanup
  - same-event transition no-op path
  - different-event transition cleanup path
  - queue untouched by default cleaner behavior

#### PR 5C
- `CurrentPhoenixSessionRepositoryTest` for:
  - explicit logout clears token/metadata and applies logout cleaner
  - auth-expiry path preserves queue and same-event cache
  - same-event login allowed
  - cross-event login blocked when foreign queued rows exist
  - cross-event login allowed when no foreign queue exists
- `SessionGateViewModelTest` for expired-session route behavior
- `AuthViewModelTest` for login error surfacing if repository throws guard failure

#### PR 5D
- doc review minimum
- if encryption is implemented, add migration and startup-open tests before any rollout

### Explicit regression traps

- wiping queued scans during logout
- clearing same-event attendee cache on auth expiry without policy approval
- allowing login to a different event while old queued rows remain
- running cleanup from UI code instead of the session boundary
- mixing DB encryption rollout into retention-policy work without an ADR decision

---

## What to Reject from Codex

Push back if Codex:

- wipes `queued_scans` on logout by default
- treats auth expiry as identical to explicit logout without policy justification
- ignores cross-event queued-row risk
- allows a new event login while foreign queued rows remain on-device
- hides the event-transition guard in UI-only logic
- starts SQLCipher or Room encryption work before the retention contract is merged
- broadens this into unrelated queue or sync refactors

---

## Recommended Merge Order

1. PR 5A — retention contract and transition policy
2. PR 5B — local runtime data cleaner and DAO helpers
3. PR 5C — session wiring and cross-event transition guard
4. PR 5D — DB-at-rest encryption ADR and optional implementation

Do not skip PR 5A.
Do not jump straight to encryption.
Do not wire cleanup before the cross-event queue rule is explicit.

---

## End State

Priority 5 is complete when:

- retention behavior is explicit and documented
- queue durability is preserved intentionally, not accidentally
- logout, auth expiry, and event changes no longer behave the same by accident
- unsafe cross-event login is blocked until explicit discard/archive tooling exists
- DB encryption is either deliberately approved with a migration plan or deliberately postponed with recorded reasons

That is the difference between “some local storage exists” and a runtime the team can actually operate with confidence.
