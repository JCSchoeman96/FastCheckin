package za.co.voelgoed.fastcheck.feature.scanning.camera

import java.time.Clock
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

/**
 * Bridges decoded raw values from the ML Kit analyzer into [ScannerCaptureEvent] instances
 * emitted by a camera-backed [za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource].
 *
 * This bridge is intentionally small: it knows only about source metadata and an emission
 * callback, not about queueing or higher-level business rules.
 */
class CameraDecodedBarcodeToSourceBridge(
    private val clock: Clock,
    private val sourceId: String?,
    private val emitCapture: (ScannerCaptureEvent) -> Unit
) : DecodedBarcodeHandler {

    override suspend fun onDecoded(rawValue: String) {
        emitCapture(
            ScannerCaptureEvent(
                rawValue = rawValue,
                capturedAtEpochMillis = clock.millis(),
                sourceType = ScannerSourceType.CAMERA,
                sourceId = sourceId
            )
        )
    }
}

