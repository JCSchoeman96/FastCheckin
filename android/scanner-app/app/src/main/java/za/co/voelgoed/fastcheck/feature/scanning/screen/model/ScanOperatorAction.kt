/**
 * Operator-facing recovery actions on the Scan destination.
 */
package za.co.voelgoed.fastcheck.feature.scanning.screen.model

enum class ScanOperatorAction {
    RequestCameraAccess,
    OpenAppSettings,
    ReconnectCamera,
    ManualSync,
    RetryUpload,
    Relogin
}
