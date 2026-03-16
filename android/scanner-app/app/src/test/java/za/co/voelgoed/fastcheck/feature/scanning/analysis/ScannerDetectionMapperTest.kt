package za.co.voelgoed.fastcheck.feature.scanning.analysis

import android.graphics.Rect
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ScannerDetectionMapperTest {
    private val mapper = ScannerDetectionMapper()

    @Test
    fun mapsRawValueBoundsAndFormatWithoutChangingNonBlankValue() {
        val detection =
            mapper.map(
                rawValue = "  VG-700  ",
                format = 256,
                bounds = Rect(1, 2, 30, 40),
                capturedAtEpochMillis = 55L
            )

        assertThat(detection?.rawValue).isEqualTo("  VG-700  ")
        assertThat(detection?.format).isEqualTo(256)
        assertThat(detection?.bounds?.left).isEqualTo(1)
        assertThat(detection?.bounds?.bottom).isEqualTo(40)
        assertThat(detection?.capturedAtEpochMillis).isEqualTo(55L)
    }

    @Test
    fun dropsNullAndBlankRawValues() {
        assertThat(mapper.map(rawValue = null, bounds = null, format = 0, capturedAtEpochMillis = 1L)).isNull()
        assertThat(mapper.map(rawValue = "   ", bounds = null, format = 0, capturedAtEpochMillis = 2L)).isNull()
    }
}
