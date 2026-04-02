# Phase 3A - Immediate Scan Semantic UI State

## Goal
Define a typed semantic UI state model for immediate scan feedback and implement mapper functions from current scanner-facing runtime types into UI semantics, without changing scanner, queueing, analyzer, API, or retry behavior.

## Scope
- In scope:
  - `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/semantic/ScanUiState.kt`
  - `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/semantic/UiStateMappers.kt`
- Out of scope:
  - Scanner pipeline behavior changes
  - Queue/retry/network behavior changes
  - API or contract changes
  - Analyzer/camera/source activation changes

## Runtime Truth Constraints
- Scanner-facing immediate outcomes are only:
  - `CaptureHandoffResult.Accepted`
  - `CaptureHandoffResult.SuppressedByCooldown`
  - `CaptureHandoffResult.Failed(reason)`
- `CaptureHandoffResult` does not preserve `QueueCreationResult` details.
- Do not infer duplicate/invalid/missing-session from `Accepted`.

## Deliverables
1. `ScanUiState.kt`
   - Typed state model for immediate scan feedback with:
     - `tone`
     - `iconKey`
     - `labelHook`
     - `defaultLabel`
   - State set: `Ready`, `Processing`, `Success`, `Suppressed`, `Failed`, conservative `Unknown`, and `OfflineRequired` only when explicitly justified by mapped source.

2. `UiStateMappers.kt`
   - Primary mapper(s): `CaptureHandoffResult -> ScanUiState`.
   - Optional helper projections for richer non-scanner types:
     - `QueueCreationResult`
     - `FlushItemResult` / `FlushReport`
   - These helpers must remain separate from immediate scanner mapping in this phase.

## Mapping Rules
- `Accepted` -> success/queued semantic only.
- `SuppressedByCooldown` -> suppression/duplicate-like semantic for cooldown, not server duplicate.
- `Failed(reason)` -> failed semantic; reason-aware classification must be conservative and fallback to `Unknown`.
- `OfflineRequired` only when source type explicitly indicates auth-expired or retryable-network requirement (not guessed from scanner accepted flow).

## Invariants
- Decode path remains: scanner source -> handoff -> local queue.
- No changes to idempotency, replay suppression, or WorkManager retry mechanics.
- No new behavioral coupling between scanner and queue/flush layers.

## Implementation Steps
1. Define sealed typed `ScanUiState` with semantic metadata fields.
2. Add mapper extensions/functions for `CaptureHandoffResult`.
3. Add conservative helper classifiers in `UiStateMappers.kt` (if needed) for queue/flush types, clearly marked as non-scanner-facing.
4. Keep current message factories and flow wiring unchanged.
5. Verify compile/lint for edited files only.

## Acceptance Criteria
- Immediate scanner feedback is typed and consistent.
- Mapping remains faithful to currently exposed scanner-facing signals.
- Duplicate/invalid/offline/unknown are not conflated where runtime already provides explicit distinctions.
- No runtime behavior changes outside semantic projection.
