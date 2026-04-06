package za.co.voelgoed.fastcheck.feature.scanning.ui.model

sealed class CaptureFeedbackState {
    data class Success(
        val title: String,
        val message: String
    ) : CaptureFeedbackState()

    data class Warning(
        val title: String,
        val message: String
    ) : CaptureFeedbackState()

    data class Error(
        val title: String,
        val message: String
    ) : CaptureFeedbackState()
}
