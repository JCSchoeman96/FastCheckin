# Scanner Pipeline

## Boundary

CameraX and ML Kit feed decoded payloads into local processing only.

`feature/scanning` owns real scanner preview, analyzer, permission, and decode
handoff work. The temporary manual/debug queue UI lives in `feature/queue`, not
in `feature/scanning`.

Pipeline:

1. camera frame enters image analysis
2. ML Kit decodes candidate barcode payload
3. decoded value is handed to `DecodedBarcodeHandler`
4. `ScanCapturePipeline` applies a short global cooldown window and, when
   eligible, forwards the raw value into the existing queue use case
5. Room queueing and per-ticket replay suppression run through the repository
   path
6. auto-flush may upload later in-process; WorkManager remains the retryable
   background fallback when it is enqueued

The pipeline ends at local queue admission only. It does not perform network
admission, server decision-making, or direct upload work.

No direct network call is allowed from analyzer code, CameraX integration, or
the immediate decode handoff path.

## Performance Rules

- use CameraX `ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST`
- do not request native camera resolution
- centralize barcode scanner configuration in one place and restrict formats
  only once the emitted FastCheck/Tickera set is confirmed

## Direction

The domain type remains future-capable, but runtime decode flows expose only
`IN`.

`OUT` remains non-operational for successful mobile business flow.

## Unresolved Normalization Question

It is not yet confirmed whether the raw QR payload always equals backend
`ticket_code`. The current runtime must preserve the scanned payload as-is and
must not introduce hidden normalization policy.

## Cooldown vs Replay Suppression

- **ScanCapturePipeline cooldown**:
  - enforces a short, global one-code-at-a-time window at the capture handoff
    boundary
  - suppressed captures surface as a distinct, non-error outcome and never
    reach the queue use case

- **Repository replay suppression**:
  - lives in the data layer and operates per ticket code over a longer window
  - prevents the same ticket from being persisted to the local queue multiple
    times in quick succession
  - remains a second line of defense and is not responsible for camera-burst
    behavior or operator-facing one-code-at-a-time guarantees

## References

- [CameraX Analyze](https://developer.android.com/media/camera/camerax/analyze)
- [ML Kit Barcode Scanning](https://developers.google.com/ml-kit/vision/barcode-scanning/android)
- [App Architecture](https://developer.android.com/topic/architecture)
- [Data Layer](https://developer.android.com/topic/architecture/data-layer)
- [Hilt on Android](https://developer.android.com/training/dependency-injection/hilt-android)
