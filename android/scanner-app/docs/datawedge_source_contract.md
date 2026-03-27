# DataWedge First Hardware Scanner Contract

## Current Seam

- Source contract: `app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain/ScannerInputSource.kt`
- Current camera source: `app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/camera/CameraScannerInputSource.kt`
- Forwarding seam: `app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScannerSourceBinding.kt`
- Cooldown and queue handoff seam: `app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`
- Shell-owned source construction and lifecycle gating: `app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

`ScannerInputSource` remains a source-only contract. Sources emit `ScannerCaptureEvent` facts and lifecycle state only. They do not queue scans, talk to repositories, call network code, or parse backend responses.

## v1 Source Selection

v1 source choice is controlled by a single shell-owned deployment/config decision, not by operator UI.

- Mechanism: `FASTCHECK_SCANNER_SOURCE` -> `BuildConfig.SCANNER_SOURCE`
- Allowed values: `camera`, `datawedge`
- v1 remains non-user-facing; there is no operator picker

## First Hardware Adapter Decision

- Zebra DataWedge is the first hardware adapter
- Support one explicit enterprise Android scanner contract first
- No keyboard wedge yet
- No multi-vendor abstraction yet

## Locked DataWedge Contract

- Broadcast action: `za.co.voelgoed.fastcheck.ACTION_SCAN`
- Payload extra: `com.symbol.datawedge.data_string`
- Expected payload: one raw scan string only
- Raw payload is preserved exactly; no source-layer normalization is applied

## Deferred Work

Keyboard wedge is deferred to the later USB-attached scanner phase.
