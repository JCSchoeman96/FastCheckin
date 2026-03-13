package za.co.voelgoed.fastcheck.feature.scanning.domain

import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState

sealed interface ScannerState {
    fun permissionState(): CameraPermissionState =
        when (this) {
            is PermissionRequired -> permissionState
            else -> CameraPermissionState.GRANTED
        }

    data class PermissionRequired(
        val permissionState: CameraPermissionState,
        val prompt: String,
        val result: ScannerResult? = null
    ) : ScannerState

    data object InitializingCamera : ScannerState

    data class Seeking(
        val lastResult: ScannerResult? = null
    ) : ScannerState

    data class CandidateDetected(
        val candidate: ScannerCandidate
    ) : ScannerState

    data class ProcessingLock(
        val candidate: ScannerCandidate
    ) : ScannerState

    data class QueuedLocally(
        val result: ScannerResult.QueuedLocally
    ) : ScannerState

    data class ReplaySuppressed(
        val result: ScannerResult.ReplaySuppressed
    ) : ScannerState

    data class Cooldown(
        val result: ScannerResult,
        val cooldown: ScannerCooldown
    ) : ScannerState
}
