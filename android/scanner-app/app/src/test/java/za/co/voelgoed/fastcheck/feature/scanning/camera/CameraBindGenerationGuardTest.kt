package za.co.voelgoed.fastcheck.feature.scanning.camera

import com.google.common.truth.Truth.assertThat
import org.junit.Test

/**
 * Verifies generation-based stale callback suppression for camera bind requests.
 */
class CameraBindGenerationGuardTest {
    @Test
    fun staleGenerationAfterStopIsIgnored() {
        val guard = CameraBindGenerationGuard()
        val first = guard.newBindGeneration()

        guard.invalidateActiveGeneration()

        assertThat(guard.isActive(first)).isFalse()
    }

    @Test
    fun olderGenerationCannotBeatNewerGeneration() {
        val guard = CameraBindGenerationGuard()
        val older = guard.newBindGeneration()
        val newer = guard.newBindGeneration()

        assertThat(guard.isActive(older)).isFalse()
        assertThat(guard.isActive(newer)).isTrue()
    }

    @Test
    fun staleSuccessLatestErrorMeansLatestWins() {
        val guard = CameraBindGenerationGuard()
        val staleSuccessGeneration = guard.newBindGeneration()
        val latestErrorGeneration = guard.newBindGeneration()

        val staleSuccessApplied = guard.isActive(staleSuccessGeneration)
        val latestErrorApplied = guard.isActive(latestErrorGeneration)

        assertThat(staleSuccessApplied).isFalse()
        assertThat(latestErrorApplied).isTrue()
    }

    @Test
    fun staleErrorLatestSuccessMeansLatestWins() {
        val guard = CameraBindGenerationGuard()
        val staleErrorGeneration = guard.newBindGeneration()
        val latestSuccessGeneration = guard.newBindGeneration()

        val staleErrorApplied = guard.isActive(staleErrorGeneration)
        val latestSuccessApplied = guard.isActive(latestSuccessGeneration)

        assertThat(staleErrorApplied).isFalse()
        assertThat(latestSuccessApplied).isTrue()
    }
}
