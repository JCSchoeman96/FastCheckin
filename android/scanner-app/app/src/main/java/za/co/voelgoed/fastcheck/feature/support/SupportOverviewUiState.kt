package za.co.voelgoed.fastcheck.feature.support

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class SupportOverviewUiState(
    val recoveryTitle: String,
    val recoveryMessage: String,
    val recoveryTone: StatusTone,
    val recoveryAction: SupportRecoveryAction?,
    val reconciliationTitle: String?,
    val reconciliationMessage: String?,
    val reconciliationTone: StatusTone?,
    val diagnosticsMessage: String,
    val sessionMessage: String
)

enum class SupportRecoveryAction(
    val label: String
) {
    RequestCameraAccess(label = "Request camera access"),
    OpenAppSettings(label = "Open app settings"),
    ReturnToScan(label = "Return to Scan")
}
