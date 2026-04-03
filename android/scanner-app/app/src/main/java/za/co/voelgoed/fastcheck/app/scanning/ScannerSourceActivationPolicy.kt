package za.co.voelgoed.fastcheck.app.scanning

sealed interface ScannerSessionState {
    data object Idle : ScannerSessionState

    data object Armed : ScannerSessionState

    data object Active : ScannerSessionState

    data class Blocked(
        val reason: ScannerBlockReason
    ) : ScannerSessionState
}

enum class ScannerBlockReason {
    NotAuthenticated,
    Backgrounded,
    PermissionDenied,
    PreviewUnavailable,
    SourceError
}

data class ScannerActivationContext(
    val sourceMode: ScannerShellSourceMode,
    val isAuthenticated: Boolean,
    val isScanDestinationSelected: Boolean,
    val isForeground: Boolean,
    val hasCameraPermission: Boolean,
    val hasPreviewSurface: Boolean,
    val isPreviewVisible: Boolean
)

data class ScannerSourceActivationDecision(
    val shouldStartBinding: Boolean,
    val shouldShowCameraPermissionRequest: Boolean,
    val sessionState: ScannerSessionState
)

class ScannerSourceActivationPolicy {
    fun evaluate(context: ScannerActivationContext): ScannerSourceActivationDecision =
        when {
            !context.isAuthenticated ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = false,
                    sessionState = ScannerSessionState.Blocked(ScannerBlockReason.NotAuthenticated)
                )

            !context.isScanDestinationSelected ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = false,
                    sessionState = ScannerSessionState.Idle
                )

            !context.isForeground ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = false,
                    sessionState = ScannerSessionState.Blocked(ScannerBlockReason.Backgrounded)
                )

            context.sourceMode.requiresCameraPermission && !context.hasCameraPermission ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = true,
                    sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PermissionDenied)
                )

            context.sourceMode.requiresCameraPermission &&
                (!context.hasPreviewSurface || !context.isPreviewVisible) ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = false,
                    sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewUnavailable)
                )

            else ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = true,
                    shouldShowCameraPermissionRequest = false,
                    sessionState = ScannerSessionState.Armed
                )
        }
}
