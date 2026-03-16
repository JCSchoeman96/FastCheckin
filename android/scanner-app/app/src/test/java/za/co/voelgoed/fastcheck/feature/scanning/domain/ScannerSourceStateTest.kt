package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerSourceStateTest {

    @Test
    fun idle_isDistinctState() {
        val state = ScannerSourceState.Idle

        assertThat(state).isInstanceOf(ScannerSourceState.Idle::class.java)
    }

    @Test
    fun starting_isDistinctState() {
        val state = ScannerSourceState.Starting

        assertThat(state).isInstanceOf(ScannerSourceState.Starting::class.java)
    }

    @Test
    fun ready_isDistinctState() {
        val state = ScannerSourceState.Ready

        assertThat(state).isInstanceOf(ScannerSourceState.Ready::class.java)
    }

    @Test
    fun stopping_isDistinctState() {
        val state = ScannerSourceState.Stopping

        assertThat(state).isInstanceOf(ScannerSourceState.Stopping::class.java)
    }

    @Test
    fun error_preservesReason() {
        val state = ScannerSourceState.Error(reason = "camera unavailable")

        assertThat(state.reason).isEqualTo("camera unavailable")
    }
}

