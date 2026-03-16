package za.co.voelgoed.fastcheck.feature.scanning.domain

data class ScannerFeedbackConfig(
    val resultCooldownMillis: Long = 1_500L
) {
    companion object {
        val default: ScannerFeedbackConfig = ScannerFeedbackConfig()
    }
}
