package za.co.voelgoed.fastcheck.feature.support

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalActionUiModel

data class SupportOverviewUiState(
    val recoveryTitle: String,
    val recoveryMessage: String,
    val recoveryTone: StatusTone,
    val recoveryAction: SupportRecoveryAction?,
    val operationalActions: List<SupportOperationalActionUiModel>,
    val reconciliationTitle: String?,
    val reconciliationMessage: String?,
    val reconciliationTone: StatusTone?,
    val diagnosticsMessage: String,
    val sessionMessage: String,
    /** Factual upload-quarantine notice; null when there are no quarantined rows. */
    val uploadQuarantineNotice: String? = null
)

enum class SupportRecoveryAction(
    val label: String
) {
    RequestCameraAccess(label = "Request camera access"),
    OpenAppSettings(label = "Open app settings"),
    ReturnToScan(label = "Return to Scan")
}
