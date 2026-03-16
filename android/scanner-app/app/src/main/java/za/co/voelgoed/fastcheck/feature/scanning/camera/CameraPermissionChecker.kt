package za.co.voelgoed.fastcheck.feature.scanning.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
open class CameraPermissionChecker @Inject constructor(
    @param:ApplicationContext private val context: Context
) {
    open fun currentState(): CameraPermissionState =
        if (
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.CAMERA
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            CameraPermissionState.GRANTED
        } else {
            CameraPermissionState.DENIED
        }
}
