package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState

class ScannerOverlayFactoryTest {
    @Test
    fun eachScannerStateMapsToOverlayModel() {
        val candidate = ScannerCandidate("VG-9", 42L)
        val queuedLocally = ScannerResult.QueuedLocally(candidate)
        val replaySuppressed = ScannerResult.ReplaySuppressed(candidate)

        val permissionOverlay =
            ScannerOverlayFactory.create(
                ScannerStateMachine.permissionRequired(CameraPermissionState.DENIED),
                nowEpochMillis = 0L
            )
        val seekingOverlay =
            ScannerOverlayFactory.create(ScannerState.Seeking(), nowEpochMillis = 0L)
        val candidateOverlay =
            ScannerOverlayFactory.create(
                ScannerState.CandidateDetected(candidate),
                nowEpochMillis = 0L
            )
        val processingOverlay =
            ScannerOverlayFactory.create(
                ScannerState.ProcessingLock(candidate),
                nowEpochMillis = 0L
            )
        val queuedOverlay =
            ScannerOverlayFactory.create(
                ScannerState.QueuedLocally(queuedLocally),
                nowEpochMillis = 0L
            )
        val replayOverlay =
            ScannerOverlayFactory.create(
                ScannerState.ReplaySuppressed(replaySuppressed),
                nowEpochMillis = 0L
            )
        val cooldownOverlay =
            ScannerOverlayFactory.create(
                ScannerState.Cooldown(
                    result = queuedLocally,
                    cooldown = ScannerCooldown.create(100L, 1_500L)
                ),
                nowEpochMillis = 400L
            )

        assertThat(permissionOverlay.headline).contains("Camera permission")
        assertThat(seekingOverlay.headline).isEqualTo("Seeking barcode")
        assertThat(candidateOverlay.candidateText).isEqualTo("VG-9")
        assertThat(processingOverlay.headline).isEqualTo("Processing scan")
        assertThat(queuedOverlay.emphasis).isEqualTo(ScannerOverlayEmphasis.SUCCESS)
        assertThat(replayOverlay.emphasis).isEqualTo(ScannerOverlayEmphasis.WARNING)
        assertThat(cooldownOverlay.cooldownRemainingMillis).isEqualTo(1_200L)
    }
}
