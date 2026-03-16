# Scanner Pipeline

## Boundary

CameraX and ML Kit feed decoded payloads into local processing only.

`feature/scanning` now owns real scanner preview, analyzer, permission, and
decode handoff work. The temporary manual/debug queue UI still lives in
`feature/queue`, not in `feature/scanning`.

Package note:

- `feature.scanning` is for the real scanner capture flow.
- `feature.queue` remains the temporary manual/debug queue UI.

Pipeline:

1. `ScannerScreen` activates `ScannerCameraBinder.bind(...)` with preview plus analyzer
2. `MlKitBarcodeFrameAnalyzer` reads `ImageProxy.image`
3. `InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)` builds the ML Kit input without `Bitmap` conversion
4. `MlKitBarcodeScannerEngine` decodes only the formats allowed by `ScannerFormatConfig`
5. `ScannerDetectionMapper` converts ML Kit detections into `ScannerDetection`
6. `ScannerFrameGate` admits at most one detection into the scanner loop while processing/cooldown is active
7. admitted detections cross the scanner feature boundary as `DecodedBarcode`
8. `ScannerLoopCoordinator` drives candidate, processing, result, and cooldown events into the scanner loop
9. `ScanCapturePipeline` forwards the raw value into the existing queue use case using scanner capture config
10. Room queueing and replay suppression run through the current repository path
11. WorkManager flushes later

No direct network call is allowed from analyzer code, CameraX integration, or
the immediate decode handoff path.

## Scanner State Machine

The real scanner loop is modeled separately from queue/flush diagnostics state.
It owns preview, analyzer gating, candidate visibility, processing lock, and
cooldown behavior only.

Allowed loop states:

- `PermissionRequired`
- `InitializingCamera`
- `Seeking`
- `CandidateDetected`
- `ProcessingLock`
- `QueuedLocally`
- `ReplaySuppressed`
- `Cooldown`

Allowed transitions:

1. permission denied or unknown -> `PermissionRequired`
2. permission granted / camera setup starts -> `InitializingCamera`
3. camera bound and analyzer active -> `Seeking`
4. analyzer emits a non-blank decoded candidate -> `CandidateDetected`
5. queue handoff begins -> `ProcessingLock`
6. local queue result -> `QueuedLocally`, `ReplaySuppressed`, or scanner-local
   mapped result visibility for missing-session / invalid-ticket outcomes
7. visible local result -> `Cooldown`
8. cooldown expiry -> `Seeking`

Critical rules:

- `ProcessingLock` prevents the scanner loop from becoming a blob of duplicate
  callbacks while the immediate local handoff is in flight.
- `Cooldown` is explicit and time-based in the scanner domain. It is not hidden
  inside UI booleans.
- `ScannerFrameGate` is admission control only. It does not own scanner state
  transitions and it is not replay suppression logic.
- scanner cooldown timing is scanner feedback config, not replay suppression policy
- Queue/flush diagnostics state stays outside the scanner loop. Scanner UI may
  show queue outcomes only after mapping them into scanner-local result and
  overlay models.
- No local backend validation states are modeled in the scanner state machine.

## Performance Rules

- use CameraX `ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST`
- bind preview and analysis through `feature.scanning.camera.ScannerCameraBinder`
- the default camera config in `feature.scanning.camera.ScannerCameraConfig` is:
  back camera, `4:3` aspect ratio, no explicit target resolution, and
  `KEEP_ONLY_LATEST`
- do not request native camera resolution by default
- centralize barcode scanner configuration in
  `feature.scanning.analysis.ScannerFormatConfig`
- the current FastCheck default allowlist is `QR_CODE`, `CODE_128`, and
  `PDF417`
- this allowlist is provisional, not a permanent claim about Tickera output
- once real FastCheck/Tickera ticket samples are verified, tighten
  `ScannerFormatConfig` to the smallest confirmed set to reduce CPU cost

These rules exist to minimize latency and avoid frame backlog.

Scanner capture metadata and scanner cooldown are Hilt-provided scanner config.
Replay suppression remains repository-owned and separate from scanner cooldown.
The current scanner screen activates the real analyzer at runtime through the
scanner feature boundary only. `ScannerCameraBinder` stays generic and does not
own analyzer selection.

## Direction

The domain type remains future-capable, but runtime decode flows expose only
`IN`.

## Unresolved Normalization Question

It is not yet confirmed whether the raw QR payload always equals backend
`ticket_code`. The current scanner runtime drops null/blank detections, but it
preserves non-blank raw values unchanged through `ScannerDetection`,
`DecodedBarcode`, and `ScannerCandidate`. Hidden trimming or parsing is not
allowed in scanner analysis code.

## References

- [CameraX Analyze](https://developer.android.com/media/camera/camerax/analyze)
- [ML Kit Barcode Scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)
- [App Architecture](https://developer.android.com/topic/architecture)
- [Data Layer](https://developer.android.com/topic/architecture/data-layer)
- [Hilt on Android](https://developer.android.com/training/dependency-injection/hilt-android)
