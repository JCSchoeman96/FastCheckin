---
name: Priority 1 docs and regression
overview: "Treat [priority-1-current-baseline-and-regression-plan.md](docs/development/priority-1-current-baseline-and-regression-plan.md) as authoritative. Priority 1 is already implemented on `main` as local-first admission (`AdmitScanUseCase`, overlays, merged truth). The old [priority-1-immediate-operator-truth-pr-plan.md](docs/development/priority-1-immediate-operator-truth-pr-plan.md) is historical only. Next work: validate current `main` code paths first, then add only missing regression coverage and required doc fixes—no feature design, no production changes unless a test proves a bug."
todos:
  - id: preflight-main-paths
    content: "Before coding: read DefaultAdmitScanUseCase, CurrentPhoenixMobileScanRepository, CurrentPhoenixSyncRepository, ScannerDao, SearchViewModel.observeSession; confirm branch names and overlay states match plan."
    status: completed
  - id: pr-1a-admit-mapper
    content: PR 1A — DefaultAdmitScanUseCaseTest + PaymentStatusRuleMapperTest with all branches listed in plan body.
    status: completed
  - id: pr-1a-overlay-lifecycle
    content: PR 1A — Explicit tests for CurrentPhoenixMobileScanRepository, CurrentPhoenixSyncRepository, ScannerDao per deliverables in plan.
    status: completed
  - id: pr-1b-search-docs
    content: PR 1B — SearchViewModel/session/clear/autoflush tests + presenter/detail tests; required doc superseded notes (phase-11 + old Priority 1 doc).
    status: completed
  - id: pr-1c-defects
    content: PR 1C only if needed — smoke-found defects; no scope creep.
    status: cancelled
isProject: false
---

# Priority 1 baseline preservation — tightened execution plan

## Authority and scope

| Document | Role |
|----------|------|
| [priority-1-current-baseline-and-regression-plan.md](docs/development/priority-1-current-baseline-and-regression-plan.md) | **Authoritative contract.** Local-first admission, overlays, merged DAO/repository truth, Search/detail/manual admit, session guards. Next steps: **preserve**, **regression-test**, **required doc alignment**, smoke—not a rebuild. |
| [priority-1-immediate-operator-truth-pr-plan.md](docs/development/priority-1-immediate-operator-truth-pr-plan.md) | **Historical only.** Five-PR queue-first sequence (`QueueCapturedScanUseCase`, handoff enrichment for “scan advisory”) does **not** match shipped `AdmitScanUseCase` + `ScanCapturePipeline` local admission. **Not executable as a roadmap.** |

**Shipped seams (validate on `main` before writing tests):**

- Gate decisions: [`DefaultAdmitScanUseCase`](android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultAdmitScanUseCase.kt)
- Operator flow: [`feature/search/`](android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/) including manual admit via **`AdmitScanUseCase`**, not a queue-first-only path
- Scan handoff: [`ScanCapturePipeline`](android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt) + local admission decisions

## Pre-implementation gate (mandatory)

1. Re-read the current implementations on `main` (names and enums drift): `DefaultAdmitScanUseCase`, overlay state types, `CurrentPhoenixMobileScanRepository` flush handling, `CurrentPhoenixSyncRepository` catch-up, `ScannerDao` queries/loaders, `SearchViewModel.observeSession` and manual-admit/autoflush wiring.
2. Only then add **missing** regression tests and doc fixes—no opportunistic refactors, no tight-file-set violations.

## Execution split (keep reviews narrow)

| PR | Focus | Contents |
|----|--------|----------|
| **PR 1A** | Data / domain regression | `DefaultAdmitScanUseCase` tests; `PaymentStatusRuleMapper` tests; overlay flush/sync/dao lifecycle tests listed below |
| **PR 1B** | Search + docs | `SearchViewModel` / presenter / detail tests for session behavior and autoflush; **required** doc updates |
| **PR 1C** | Only if needed | Defects found in smoke or tests; **no** new features |

If a single PR is unavoidable, enforce a **tight changed-file set** and **no** opportunistic refactors.

---

## PR 1A — `DefaultAdmitScanUseCase` tests (explicit branches)

Add [`DefaultAdmitScanUseCaseTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultAdmitScanUseCaseTest.kt) (or equivalent package) covering **every meaningful branch** in the current use case:

1. Invalid ticket normalization → **rejection**
2. Missing session context → **review required**
3. Untrusted cache → **review required**
4. Ticket not found → **rejection**
5. Conflict overlay → **rejection**
6. Already inside → **rejection**
7. No check-ins remaining → **rejection**
8. Payment blocked → **rejection**
9. Payment unknown → **review required**
10. Successful accept → **accepted** (queue + overlay path as implemented)
11. Replay-suppressed duplicate local write → **safe rejection** (per current semantics)
12. Local write failure → **review required** (or failure path as coded)

Adjust expected types to match **actual** `LocalAdmissionDecision` variants on `main` after the preflight read.

---

## PR 1A — `PaymentStatusRuleMapper` tests

Add [`PaymentStatusRuleMapperTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/PaymentStatusRuleMapperTest.kt):

- Known allowed statuses → `ALLOWED`
- Known blocked statuses → `BLOCKED`
- Unknown statuses → `UNKNOWN`
- Normalization is case-insensitive and deterministic

---

## PR 1A — Overlay / flush / sync / DAO lifecycle (replaces vague “gap-audit”)

These are **explicit deliverables**—not a post-hoc audit.

### `CurrentPhoenixMobileScanRepositoryTest` (extend or add)

Validate against **current** flush outcome handling:

- Flush success moves overlay to **`CONFIRMED_LOCAL_UNSYNCED`** (or current equivalent name after preflight)
- Duplicate outcome moves overlay to **`CONFLICT_DUPLICATE`** (or equivalent)
- Terminal non-duplicate rejection moves overlay to **`CONFLICT_REJECTED`** (or equivalent)
- Retryable / auth-expired outcomes **do not** transition overlays in a way that contradicts production rules (assert current behavior)

### `CurrentPhoenixSyncRepositoryTest` (extend or add)

- Confirmed overlay is **removed only when** synced attendee row satisfies catch-up policy
- Mismatched/older synced state **does not** remove overlay prematurely

### `ScannerDaoTest` (extend or add)

- Merged unresolved-event loaders include **queued scans and overlays** as implemented
- Active overlay queries return **only** active states (per DAO definition on `main`)

**Note:** Exact enum/state strings must be taken from `main` after preflight—rename tests if the codebase uses different identifiers.

---

## PR 1B — Search session behavior (explicit tests)

`SearchViewModel.observeSession(...)` resets query, selection, and manual-action state when the observed session changes. Tests must lock:

| Behavior | Expected |
|----------|----------|
| Same session | **does not** reset |
| Different authenticated session | **does** reset |
| Clear search | wipes query + selection + manual action state |
| Manual admit success | **autoflush only** when decision is an **accepted** local admission |
| Rejected / review / failure | **does not** request autoflush |

**Files to touch (typical):** [`SearchViewModelTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/SearchViewModelTest.kt), plus presenter/detail tests as needed for merged-truth copy and manual-admit feedback (no layout/screenshot tests).

---

## PR 1B — Documentation (required, not optional)

1. **[`docs/development/done/phase-11-attendee-search-and-manual-checkin-foundation.md`](docs/development/done/phase-11-attendee-search-and-manual-checkin-foundation.md)**  
   - Add a **superseded / runtime-shift** note at the top: `feature/search/`, `AdmitScanUseCase`, etc.
2. **[`docs/development/priority-1-immediate-operator-truth-pr-plan.md`](docs/development/priority-1-immediate-operator-truth-pr-plan.md)**  
   - Add a **top-of-file** banner pointing to [priority-1-current-baseline-and-regression-plan.md](docs/development/priority-1-current-baseline-and-regression-plan.md) as the only executable Priority 1 contract.

**Goal:** No one can open the old doc first and treat it as a live implementation plan.

---

## Missing-test matrix (pre-code precision)

| Area | Existing tests | Missing tests | Files to add or extend |
|------|----------------|---------------|-------------------------|
| Admit use case | partial / none | All decision branches in §“PR 1A — DefaultAdmitScanUseCase” | `DefaultAdmitScanUseCaseTest.kt` |
| Payment mapping | none | allowed / blocked / unknown / normalization | `PaymentStatusRuleMapperTest.kt` |
| Search | none / partial | Session reset, clear, autoflush only on accept | `SearchViewModelTest.kt`, presenter/detail tests |
| Overlay lifecycle | partial (`OverlayCatchUpPolicyTest`, etc.) | Flush-state transitions + sync catch-up removal + DAO loaders/queries | `CurrentPhoenixMobileScanRepositoryTest` / `CurrentPhoenixSyncRepositoryTest` / `ScannerDaoTest` |
| Docs | stale | Superseded notes + cross-links | phase-11 done doc + old Priority 1 doc |

---

## What to avoid

- Reopening feature design or Priority 2 operator-controls work
- Touching production logic **unless** a test exposes a real bug
- Renaming large folders/modules
- Re-litigating queue-first vs local-first
- Mixing Priority 1 preservation with unrelated refactors

---

## Success criteria

- **Docs:** No stale doc can mislead the next agent; old Priority 1 plan is clearly non-executable.
- **Admit path:** All major `DefaultAdmitScanUseCase` branches have direct tests.
- **Search:** Session/clear/autoflush behavior is locked by tests.
- **Overlays:** Flush transitions and sync catch-up removal are explicitly tested at repository/DAO boundaries.
- **No new runtime design** introduced.

---

## Validation commands (per PR)

```bash
git diff --check
# From android/scanner-app — adjust JAVA_HOME to local JDK 25 as in AGENTS.md
./gradlew :app:compileDebugKotlin :app:testDebugUnitTest
```

If Elixir/docs-only: `mix precommit` when repo root files change.

---

## Existing coverage (context only, not a substitute for matrix)

Examples already in tree: [`OverlayCatchUpPolicyTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/OverlayCatchUpPolicyTest.kt), [`CurrentEventAdmissionReadinessTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/domain/policy/CurrentEventAdmissionReadinessTest.kt), [`SessionGateViewModelTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt), [`ScanCapturePipelineTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/ScanCapturePipelineTest.kt), [`EventDestinationPresenterTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenterTest.kt), [`AttendeeLookupDaoTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/local/AttendeeLookupDaoTest.kt), [`RuntimeContractAuditTest.kt`](android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/RuntimeContractAuditTest.kt).
