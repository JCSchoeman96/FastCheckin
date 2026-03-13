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

1. camera frame enters image analysis
2. ML Kit decodes candidate barcode payload
3. decoded value is handed to `DecodedBarcodeHandler`
4. `ScanCapturePipeline` forwards the raw value into the existing queue use case
5. Room queueing and replay suppression run through the current repository path
6. WorkManager flushes later

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
- Queue/flush diagnostics state stays outside the scanner loop. Scanner UI may
  show queue outcomes only after mapping them into scanner-local result and
  overlay models.
- No local backend validation states are modeled in the scanner state machine.

## Performance Rules

- use CameraX `ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST`
- do not request native camera resolution
- centralize barcode scanner configuration in
  `feature.scanning.analysis.ScannerFormatConfig`
- the current FastCheck default allowlist is `QR_CODE`, `CODE_128`, and
  `PDF417`
- this allowlist is provisional, not a permanent claim about Tickera output
- once real FastCheck/Tickera ticket samples are verified, tighten
  `ScannerFormatConfig` to the smallest confirmed set to reduce CPU cost

These rules exist to minimize latency and avoid frame backlog.

## Direction

The domain type remains future-capable, but runtime decode flows expose only
`IN`.

## Unresolved Normalization Question

It is not yet confirmed whether the raw QR payload always equals backend
`ticket_code`. The current runtime must preserve the scanned payload as-is and
must not introduce hidden normalization policy.

## References

- [CameraX Analyze](https://developer.android.com/media/camera/camerax/analyze)
- [ML Kit Barcode Scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)
- [App Architecture](https://developer.android.com/topic/architecture)
- [Data Layer](https://developer.android.com/topic/architecture/data-layer)
- [Hilt on Android](https://developer.android.com/training/dependency-injection/hilt-android)
