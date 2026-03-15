package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

class ScannerFrameGateTest {
    @Test
    fun admitsFirstDetectionAndSuppressesFurtherAdmissionsUntilRelease() {
        val gate = ScannerFrameGate()
        val first = ScannerDetection("VG-1", null, 1, 1L)
        val second = ScannerDetection("VG-2", null, 1, 2L)

        assertThat(gate.tryAdmit(first)).isTrue()
        assertThat(gate.tryAdmit(second)).isFalse()

        gate.release()

        assertThat(gate.tryAdmit(second)).isTrue()
    }

    @Test
    fun resetReopensAdmissionWithoutOwningScannerState() {
        val gate = ScannerFrameGate()
        val detection = ScannerDetection("VG-1", null, 1, 1L)

        gate.tryAdmit(detection)
        gate.reset()

        assertThat(gate.tryAdmit(detection)).isTrue()
    }
}
