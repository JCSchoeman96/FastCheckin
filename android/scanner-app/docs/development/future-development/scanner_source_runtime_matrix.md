# Scanner Source Runtime Matrix

## Purpose

This matrix gives future implementation work a compact reference for how FastCheck
scanner source modes should differ in runtime behavior without changing the
shared queue, auth, and admission truth model.

This is a future-development document only.

## Shared Runtime Rules

These rules apply to every row in the matrix:

- source capture feeds local queue handoff only
- source adapters do not call network code directly
- backend admission still happens through the current mobile upload path
- source type does not create a second auth or session model
- local queue acceptance is not server-confirmed admission
- auto-flush remains normal
- manual flush remains fallback and support

## Runtime Matrix

| Source type | Current repo support state | MVP priority | Permission requirements | Activation model | Foreground/background behavior | Battery considerations | Operator-facing UI differences | Support/admin implications | Future implementation phase |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `CAMERA` | Implemented and selectable today through `FASTCHECK_SCANNER_SOURCE=camera`; backed by `CameraScannerInputSource`, preview binding, and source-aware shell gating | Priority 1; reference product path | Runtime camera permission required | Explicit scan-surface ownership; active when authenticated, foregrounded, on `Scan`, preview-ready, and permission-granted | Backgrounded app, lost permission, lost preview, logout, or non-`Scan` destination should stop or block capture eligibility | Highest app-owned battery cost because preview and analysis run continuously | Uses preview-centric readiness, permission recovery, and visible scan-state messaging | Lower provisioning burden; more operator-visible permission recovery | Baseline already exists; future work is refinement and stabilization of the smartphone-first path |
| `BROADCAST_INTENT` | Source seam exists today through `DataWedgeScannerInputSource` and `FASTCHECK_SCANNER_SOURCE=datawedge`; shell and UI already recognize non-camera operation | Priority 2; first hardware expansion path after smartphone runtime proves stable | No camera permission path | Can be described as source-ready without preview, but still must stay inside authenticated shell and destination ownership rules | No preview dependency; can feel more continuously armed while foregrounded, but must still respect auth, foreground, and destination state | Lower app-owned battery pressure than camera mode because the app is not running a camera preview pipeline | Preview is not central; status should emphasize readiness, capture handoff, and source health instead of camera state | Higher support burden because provisioning, DataWedge profile health, and diagnostics matter more than on camera mode | First future hardware productization phase |
| `KEYBOARD_WEDGE` | Enum exists in `ScannerSourceType`, but there is no active shell selection, no source implementation, and no promoted runtime contract for it | Deferred; lower than DataWedge and not assumed next | Likely no camera permission, but exact platform/input handling rules are not yet locked | Unknown until explicitly designed; must not be inferred from camera or DataWedge behavior | Unknown; future work must define focus, input, and accidental-capture policy explicitly | Likely lower camera-style battery cost, but input/focus risks could create different operational costs | Must not inherit preview UI; likely needs explicit focus and accidental-input policy if ever implemented | Likely support-heavy because keyboard input behavior and device variance need validation | Evaluate only after smartphone baseline and DataWedge support are stable and justified |

## Interpretation Notes

### Why `CAMERA` stays the reference

`CAMERA` remains the reference row because the current product is still
smartphone-first. Future hardware work should adapt to this shell and truth
model instead of forcing the smartphone path to absorb hardware assumptions.

### Why `BROADCAST_INTENT` is next

`BROADCAST_INTENT` is next because the repo already contains:

- `DataWedgeScannerInputSource`
- a `datawedge` shell mode
- source-aware permission and preview behavior

That makes it the first realistic hardware expansion path.

### Why `KEYBOARD_WEDGE` remains deferred

`KEYBOARD_WEDGE` is intentionally present in the enum without a runtime path.
That should be treated as future capability reservation, not as a commitment to
implement it next.

## Grounding References

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/docs/scanner_interaction_policy.md`
- `android/scanner-app/docs/scanner_pipeline.md`
- `android/scanner-app/docs/datawedge_source_contract.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain/ScannerSourceType.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain/ScannerInputSource.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/scanning/ScannerSourceSelection.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/camera/CameraScannerInputSource.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/broadcast/DataWedgeScannerInputSource.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
