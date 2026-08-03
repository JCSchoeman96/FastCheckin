package za.co.voelgoed.fastcheck.core.sync

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class AttendeeSyncBootstrapStateHubTest {
    @Test
    fun completingOneEventDoesNotClearAnotherEventsBootstrapState() {
        val hub = AttendeeSyncBootstrapStateHub()

        hub.notifyInitialBootstrapSyncActive(7L, true)
        hub.notifyInitialBootstrapSyncActive(8L, true)
        hub.notifyInitialBootstrapSyncActive(7L, false)

        assertThat(hub.isInitialBootstrapSyncInProgressForEvent(7L)).isFalse()
        assertThat(hub.isInitialBootstrapSyncInProgressForEvent(8L)).isTrue()
    }
}
