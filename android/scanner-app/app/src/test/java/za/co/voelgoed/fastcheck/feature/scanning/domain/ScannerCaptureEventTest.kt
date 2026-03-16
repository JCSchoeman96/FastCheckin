package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerCaptureEventTest {

    @Test
    fun preservesProvidedValues() {
        val event = ScannerCaptureEvent(
            rawValue = "VG-101",
            capturedAtEpochMillis = 1_700_000_000_000L,
            sourceType = ScannerSourceType.CAMERA,
            sourceId = "camera-0"
        )

        assertThat(event.rawValue).isEqualTo("VG-101")
        assertThat(event.capturedAtEpochMillis).isEqualTo(1_700_000_000_000L)
        assertThat(event.sourceType).isEqualTo(ScannerSourceType.CAMERA)
        assertThat(event.sourceId).isEqualTo("camera-0")
    }

    @Test
    fun allowsNullSourceId() {
        val event = ScannerCaptureEvent(
            rawValue = "VG-102",
            capturedAtEpochMillis = 1_700_000_000_001L,
            sourceType = ScannerSourceType.KEYBOARD_WEDGE,
            sourceId = null
        )

        assertThat(event.sourceId).isNull()
        assertThat(event.sourceType).isEqualTo(ScannerSourceType.KEYBOARD_WEDGE)
    }
}

