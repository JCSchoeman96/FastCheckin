package za.co.voelgoed.fastcheck.feature.scanning.domain

object ScannerOverlayFactory {
    fun create(
        scannerState: ScannerState,
        nowEpochMillis: Long
    ): ScannerOverlayModel =
        when (scannerState) {
            is ScannerState.PermissionRequired ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Camera permission required",
                    message = scannerState.prompt,
                    candidateText = null,
                    emphasis =
                        if (scannerState.result is ScannerResult.InitializationFailure) {
                            ScannerOverlayEmphasis.ERROR
                        } else {
                            ScannerOverlayEmphasis.WARNING
                        },
                    cooldownRemainingMillis = null
                )

            ScannerState.InitializingCamera ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Initializing camera",
                    message = "Preparing camera preview.",
                    candidateText = null,
                    emphasis = ScannerOverlayEmphasis.NEUTRAL,
                    cooldownRemainingMillis = null
                )

            is ScannerState.Seeking ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Seeking barcode",
                    message =
                        when (val result = scannerState.lastResult) {
                            is ScannerResult.InitializationFailure ->
                                result.message ?: "Scanner preview could not start."

                            is ScannerResult.MissingSessionContext ->
                                "Login is required before local queue handoff can continue."

                            is ScannerResult.InvalidTicketCode ->
                                "Ticket code is required."

                            else ->
                                "Point the camera at a ticket QR code."
                        },
                    candidateText = scannerState.lastResult?.candidate?.rawValue,
                    emphasis =
                        if (scannerState.lastResult is ScannerResult.InitializationFailure) {
                            ScannerOverlayEmphasis.ERROR
                        } else {
                            ScannerOverlayEmphasis.NEUTRAL
                        },
                    cooldownRemainingMillis = null
                )

            is ScannerState.CandidateDetected ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Candidate detected",
                    message = "Preparing local queue handoff.",
                    candidateText = scannerState.candidate.rawValue,
                    emphasis = ScannerOverlayEmphasis.NEUTRAL,
                    cooldownRemainingMillis = null
                )

            is ScannerState.ProcessingLock ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Processing scan",
                    message = "Duplicate analyzer callbacks are locked until the local handoff finishes.",
                    candidateText = scannerState.candidate.rawValue,
                    emphasis = ScannerOverlayEmphasis.NEUTRAL,
                    cooldownRemainingMillis = null
                )

            is ScannerState.QueuedLocally ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Queued locally",
                    message = "Scan stored locally and ready for later flush.",
                    candidateText = scannerState.result.candidate.rawValue,
                    emphasis = ScannerOverlayEmphasis.SUCCESS,
                    cooldownRemainingMillis = null
                )

            is ScannerState.ReplaySuppressed ->
                ScannerOverlayModel(
                    visible = true,
                    headline = "Replay suppressed",
                    message = "Repeated ticket_code ignored inside the local replay window.",
                    candidateText = scannerState.result.candidate.rawValue,
                    emphasis = ScannerOverlayEmphasis.WARNING,
                    cooldownRemainingMillis = null
                )

            is ScannerState.Cooldown ->
                ScannerOverlayModel(
                    visible = true,
                    headline = cooldownHeadline(scannerState.result),
                    message = cooldownMessage(scannerState.result),
                    candidateText = scannerState.result.candidate?.rawValue,
                    emphasis = cooldownEmphasis(scannerState.result),
                    cooldownRemainingMillis = scannerState.cooldown.remainingMillis(nowEpochMillis)
                )
        }

    private fun cooldownHeadline(result: ScannerResult): String =
        when (result) {
            is ScannerResult.QueuedLocally -> "Queued locally"
            is ScannerResult.ReplaySuppressed -> "Replay suppressed"
            is ScannerResult.MissingSessionContext -> "Login required"
            is ScannerResult.InvalidTicketCode -> "Invalid scan"
            is ScannerResult.InitializationFailure -> "Camera unavailable"
        }

    private fun cooldownMessage(result: ScannerResult): String =
        when (result) {
            is ScannerResult.QueuedLocally ->
                "Scan stored locally and visible during cooldown."

            is ScannerResult.ReplaySuppressed ->
                "Repeated ticket_code ignored inside the cooldown window."

            is ScannerResult.MissingSessionContext ->
                "Login is required before local queue handoff can continue."

            is ScannerResult.InvalidTicketCode ->
                "Ticket code is required."

            is ScannerResult.InitializationFailure ->
                result.message ?: "Scanner preview could not start."
        }

    private fun cooldownEmphasis(result: ScannerResult): ScannerOverlayEmphasis =
        when (result) {
            is ScannerResult.QueuedLocally -> ScannerOverlayEmphasis.SUCCESS
            is ScannerResult.ReplaySuppressed -> ScannerOverlayEmphasis.WARNING
            is ScannerResult.MissingSessionContext,
            is ScannerResult.InvalidTicketCode,
            is ScannerResult.InitializationFailure -> ScannerOverlayEmphasis.ERROR
        }
}
