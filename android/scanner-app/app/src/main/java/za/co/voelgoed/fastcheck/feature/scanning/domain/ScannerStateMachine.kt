package za.co.voelgoed.fastcheck.feature.scanning.domain

object ScannerStateMachine {
    fun onPermissionUpdated(isGranted: Boolean): ScannerState =
        if (isGranted) {
            ScannerState.InitializingCamera
        } else {
            permissionRequired(CameraPermissionState.DENIED)
        }

    fun permissionRequired(
        permissionState: CameraPermissionState,
        prompt: String = defaultPermissionPrompt(permissionState),
        result: ScannerResult? = null
    ): ScannerState.PermissionRequired =
        ScannerState.PermissionRequired(
            permissionState = permissionState,
            prompt = prompt,
            result = result
        )

    fun onPermissionRequestStarted(currentPermissionState: CameraPermissionState): ScannerState.PermissionRequired =
        permissionRequired(
            permissionState = currentPermissionState,
            prompt = "Requesting camera permission for scanner preview."
        )

    fun onCameraBindingStarted(): ScannerState = ScannerState.InitializingCamera

    fun onCameraReady(): ScannerState = ScannerState.Seeking()

    fun onCandidateDetected(candidate: ScannerCandidate): ScannerState =
        ScannerState.CandidateDetected(candidate)

    fun onProcessingStarted(candidate: ScannerCandidate): ScannerState =
        ScannerState.ProcessingLock(candidate)

    fun onResultVisible(result: ScannerResult): ScannerState =
        when (result) {
            is ScannerResult.QueuedLocally -> ScannerState.QueuedLocally(result)
            is ScannerResult.ReplaySuppressed -> ScannerState.ReplaySuppressed(result)
            is ScannerResult.MissingSessionContext,
            is ScannerResult.InvalidTicketCode,
            is ScannerResult.InitializationFailure -> {
                ScannerState.Seeking(lastResult = result)
            }
        }

    fun onCooldownStarted(
        result: ScannerResult,
        startedAtEpochMillis: Long,
        cooldownMillis: Long = ScannerCaptureDefaults.resultCooldownMillis
    ): ScannerState =
        ScannerState.Cooldown(
            result = result,
            cooldown = ScannerCooldown.create(startedAtEpochMillis, cooldownMillis)
        )

    fun onCooldownComplete(): ScannerState = ScannerState.Seeking()

    fun onCameraFailure(
        permissionState: CameraPermissionState,
        message: String?,
        retryable: Boolean
    ): ScannerState {
        val result = ScannerResult.InitializationFailure(message)

        return if (permissionState == CameraPermissionState.GRANTED && retryable) {
            ScannerState.Seeking(lastResult = result)
        } else {
            permissionRequired(permissionState = permissionState, result = result)
        }
    }

    private fun defaultPermissionPrompt(permissionState: CameraPermissionState): String =
        when (permissionState) {
            CameraPermissionState.UNKNOWN ->
                "Camera permission status unknown."

            CameraPermissionState.DENIED ->
                "Camera permission required before scanner preview can start."

            CameraPermissionState.GRANTED ->
                "Camera permission granted."
        }
}
