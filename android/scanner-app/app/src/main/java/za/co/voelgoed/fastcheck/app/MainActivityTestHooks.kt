package za.co.voelgoed.fastcheck.app

import android.content.Intent
import androidx.annotation.VisibleForTesting
import za.co.voelgoed.fastcheck.app.scanning.ScannerShellSourceMode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource

@VisibleForTesting
object MainActivityTestHooks {
    @Volatile
    var scannerInputSourceFactory: ((ScannerShellSourceMode) -> ScannerInputSource)? = null

    @Volatile
    var onCameraPermissionRequest: (() -> Unit)? = null

    @Volatile
    var onOpenAppSettings: ((Intent) -> Unit)? = null

    @Volatile
    var permissionStateOverride: CameraPermissionOverride? = null

    @Volatile
    var previewSurfaceOverride: PreviewSurfaceOverride? = null

    fun reset() {
        scannerInputSourceFactory = null
        onCameraPermissionRequest = null
        onOpenAppSettings = null
        permissionStateOverride = null
        previewSurfaceOverride = null
    }
}

data class CameraPermissionOverride(
    val isGranted: Boolean,
    val shouldShowRationale: Boolean
)

data class PreviewSurfaceOverride(
    val hasPreviewSurface: Boolean,
    val isPreviewVisible: Boolean
)
