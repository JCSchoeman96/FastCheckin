package za.co.voelgoed.fastcheck.feature.scanning.domain

data class ScannerOverlayModel(
    val visible: Boolean,
    val headline: String,
    val message: String?,
    val candidateText: String?,
    val emphasis: ScannerOverlayEmphasis,
    val cooldownRemainingMillis: Long?
)

enum class ScannerOverlayEmphasis {
    NEUTRAL,
    SUCCESS,
    WARNING,
    ERROR
}
