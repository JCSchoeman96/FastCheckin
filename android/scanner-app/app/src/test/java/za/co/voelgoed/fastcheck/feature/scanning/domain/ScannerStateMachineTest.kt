package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState

class ScannerStateMachineTest {
    private val feedbackConfig = ScannerFeedbackConfig.default

    @Test
    fun permissionRequiredTransitionsIntoInitializingAndSeeking() {
        assertThat(ScannerStateMachine.permissionRequired(CameraPermissionState.UNKNOWN))
            .isEqualTo(
                ScannerState.PermissionRequired(
                    permissionState = CameraPermissionState.UNKNOWN,
                    prompt = "Camera permission status unknown."
                )
            )

        assertThat(ScannerStateMachine.onPermissionUpdated(true))
            .isEqualTo(ScannerState.InitializingCamera)

        assertThat(ScannerStateMachine.onCameraReady())
            .isEqualTo(ScannerState.Seeking())
    }

    @Test
    fun queuedLocallyPathMovesFromCandidateToCooldownAndBackToSeeking() {
        val candidate = ScannerCandidate("VG-1", 10L)

        assertThat(ScannerStateMachine.onCandidateDetected(candidate))
            .isEqualTo(ScannerState.CandidateDetected(candidate))
        assertThat(ScannerStateMachine.onProcessingStarted(candidate))
            .isEqualTo(ScannerState.ProcessingLock(candidate))

        val result = ScannerResult.QueuedLocally(candidate)
        assertThat(ScannerStateMachine.onResultVisible(result))
            .isEqualTo(ScannerState.QueuedLocally(result))

        val cooldownState =
            ScannerStateMachine.onCooldownStarted(
                result,
                startedAtEpochMillis = 100L,
                cooldownMillis = feedbackConfig.resultCooldownMillis
            )
        assertThat(cooldownState)
            .isEqualTo(
                ScannerState.Cooldown(
                    result = result,
                    cooldown = ScannerCooldown.create(100L, feedbackConfig.resultCooldownMillis)
                )
            )

        assertThat(ScannerStateMachine.onCooldownComplete())
            .isEqualTo(ScannerState.Seeking())
    }

    @Test
    fun replaySuppressedPathMovesFromCandidateToCooldownAndBackToSeeking() {
        val candidate = ScannerCandidate("VG-2", 20L)
        val result = ScannerResult.ReplaySuppressed(candidate)

        assertThat(ScannerStateMachine.onCandidateDetected(candidate))
            .isEqualTo(ScannerState.CandidateDetected(candidate))
        assertThat(ScannerStateMachine.onProcessingStarted(candidate))
            .isEqualTo(ScannerState.ProcessingLock(candidate))
        assertThat(ScannerStateMachine.onResultVisible(result))
            .isEqualTo(ScannerState.ReplaySuppressed(result))
        assertThat(
            ScannerStateMachine.onCooldownStarted(
                result,
                startedAtEpochMillis = 200L,
                cooldownMillis = feedbackConfig.resultCooldownMillis
            )
        )
            .isEqualTo(
                ScannerState.Cooldown(
                    result = result,
                    cooldown = ScannerCooldown.create(200L, feedbackConfig.resultCooldownMillis)
                )
            )
    }

    @Test
    fun invalidAndMissingSessionResultsStayScannerLocal() {
        val candidate = ScannerCandidate("VG-3", 30L)
        val missingSession = ScannerResult.MissingSessionContext(candidate)
        val invalidTicket = ScannerResult.InvalidTicketCode(candidate)

        assertThat(ScannerStateMachine.onResultVisible(missingSession))
            .isEqualTo(ScannerState.Seeking(lastResult = missingSession))
        assertThat(ScannerStateMachine.onResultVisible(invalidTicket))
            .isEqualTo(ScannerState.Seeking(lastResult = invalidTicket))
    }
}
