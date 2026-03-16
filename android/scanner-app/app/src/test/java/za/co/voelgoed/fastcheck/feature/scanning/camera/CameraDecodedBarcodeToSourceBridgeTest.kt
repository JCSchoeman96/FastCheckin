package za.co.voelgoed.fastcheck.feature.scanning.camera

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

class CameraDecodedBarcodeToSourceBridgeTest {

    @Test
    fun emitsScannerCaptureEventWithExpectedFields() = runTest {
        val fixedInstant = Instant.ofEpochMilli(1_700_000_000_000L)
        val clock = Clock.fixed(fixedInstant, ZoneOffset.UTC)
        val received = mutableListOf<za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent>()

        val bridge =
            CameraDecodedBarcodeToSourceBridge(
                clock = clock,
                sourceId = "camera-0",
                emitCapture = { event -> received += event }
            )

        bridge.onDecoded("  VG-101  ")

        assertThat(received).hasSize(1)
        val event = received.single()
        assertThat(event.rawValue).isEqualTo("  VG-101  ")
        assertThat(event.capturedAtEpochMillis).isEqualTo(1_700_000_000_000L)
        assertThat(event.sourceType).isEqualTo(ScannerSourceType.CAMERA)
        assertThat(event.sourceId).isEqualTo("camera-0")
    }
}

