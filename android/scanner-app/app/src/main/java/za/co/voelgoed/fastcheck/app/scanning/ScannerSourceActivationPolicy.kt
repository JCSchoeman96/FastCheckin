package za.co.voelgoed.fastcheck.app.scanning

data class ScannerSourceActivationDecision(
    val shouldStartBinding: Boolean,
    val shouldShowCameraPermissionRequest: Boolean
)

class ScannerSourceActivationPolicy {
    fun evaluate(
        sourceMode: ScannerShellSourceMode,
        hasCameraPermission: Boolean,
        isShellStarted: Boolean
    ): ScannerSourceActivationDecision =
        when {
            !isShellStarted ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = false,
                    shouldShowCameraPermissionRequest = sourceMode.requiresCameraPermission
                )
            sourceMode.requiresCameraPermission ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = hasCameraPermission,
                    shouldShowCameraPermissionRequest = !hasCameraPermission
                )
            else ->
                ScannerSourceActivationDecision(
                    shouldStartBinding = true,
                    shouldShowCameraPermissionRequest = false
                )
        }
}
