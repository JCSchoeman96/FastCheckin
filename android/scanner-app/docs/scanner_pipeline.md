# Scanner Pipeline

## Boundary

CameraX and ML Kit feed decoded payloads into local processing only.

`feature/scanning` now owns real scanner preview, analyzer, permission, and
decode handoff work. The temporary manual/debug queue UI still lives in
`feature/queue`, not in `feature/scanning`.

Pipeline:

1. camera frame enters image analysis
2. ML Kit decodes candidate barcode payload
3. decoded value is handed to `DecodedBarcodeHandler`
4. `ScanCapturePipeline` forwards the raw value into the existing queue use case
5. Room queueing and replay suppression run through the current repository path
6. WorkManager flushes later

No direct network call is allowed from analyzer code, CameraX integration, or
the immediate decode handoff path.

## Performance Rules

- use CameraX `ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST`
- do not request native camera resolution
- centralize barcode scanner configuration in one place and restrict formats
  only once the emitted FastCheck/Tickera set is confirmed

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
