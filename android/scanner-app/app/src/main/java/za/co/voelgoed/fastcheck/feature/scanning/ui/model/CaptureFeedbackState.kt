package za.co.voelgoed.fastcheck.feature.scanning.ui.model

sealed class CaptureFeedbackState {
    data class Success(val message: String) : CaptureFeedbackState()
    data class Warning(val message: String) : CaptureFeedbackState()
    data class Error(val message: String) : CaptureFeedbackState()
}

