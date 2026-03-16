package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerCooldownTest {
    @Test
    fun explicitRemainingTimeIsDerivedFromEndTimestamp() {
        val cooldown = ScannerCooldown.create(startedAtEpochMillis = 1_000L, durationMillis = 1_500L)

        assertThat(cooldown.endsAtEpochMillis).isEqualTo(2_500L)
        assertThat(cooldown.remainingMillis(1_200L)).isEqualTo(1_300L)
        assertThat(cooldown.remainingMillis(3_000L)).isEqualTo(0L)
    }
}
