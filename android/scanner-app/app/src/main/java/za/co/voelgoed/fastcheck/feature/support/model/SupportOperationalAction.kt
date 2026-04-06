/**
 * Operational recovery actions on Support (sync/upload/re-auth), separate from
 * [za.co.voelgoed.fastcheck.feature.support.SupportRecoveryAction] scanner/device recovery.
 */
package za.co.voelgoed.fastcheck.feature.support.model

enum class SupportOperationalAction {
    ManualSync,
    RetryUpload,
    Relogin
}

data class SupportOperationalActionUiModel(
    val label: String,
    val action: SupportOperationalAction
)
