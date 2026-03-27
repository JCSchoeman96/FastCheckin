package za.co.voelgoed.fastcheck.app.scanning

import za.co.voelgoed.fastcheck.BuildConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

enum class ScannerShellSourceMode(
    val wireName: String,
    val sourceType: ScannerSourceType,
    val requiresCameraPermission: Boolean
) {
    CAMERA(
        wireName = "camera",
        sourceType = ScannerSourceType.CAMERA,
        requiresCameraPermission = true
    ),
    DATAWEDGE(
        wireName = "datawedge",
        sourceType = ScannerSourceType.BROADCAST_INTENT,
        requiresCameraPermission = false
    );

    companion object {
        fun fromBuildConfig(value: String): ScannerShellSourceMode =
            entries.firstOrNull { it.wireName.equals(value.trim(), ignoreCase = true) }
                ?: throw IllegalArgumentException("Unknown FASTCHECK_SCANNER_SOURCE '$value'.")
    }
}

class ScannerSourceSelectionResolver {
    fun resolve(sourceValue: String = BuildConfig.SCANNER_SOURCE): ScannerShellSourceMode =
        ScannerShellSourceMode.fromBuildConfig(sourceValue)
}
