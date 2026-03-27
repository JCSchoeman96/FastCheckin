package za.co.voelgoed.fastcheck.app.scanning

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerSourceSelectionResolverTest {
    private val resolver = ScannerSourceSelectionResolver()

    @Test
    fun resolvesCameraModeFromWireName() {
        val mode = resolver.resolve("camera")

        assertThat(mode).isEqualTo(ScannerShellSourceMode.CAMERA)
        assertThat(mode.requiresCameraPermission).isTrue()
    }

    @Test
    fun resolvesDataWedgeModeFromWireName() {
        val mode = resolver.resolve("datawedge")

        assertThat(mode).isEqualTo(ScannerShellSourceMode.DATAWEDGE)
        assertThat(mode.requiresCameraPermission).isFalse()
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsUnknownSourceMode() {
        resolver.resolve("keyboard-wedge")
    }
}
