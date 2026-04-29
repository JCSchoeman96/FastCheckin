package za.co.voelgoed.fastcheck.feature.scanning.screen

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

/** Presents scan-screen attendee cache freshness state and refresh action affordance. */
data class ScanRefreshUiModel(
    val message: String,
    val tone: StatusTone,
    val buttonVisible: Boolean,
    val buttonEnabled: Boolean,
    val buttonLabel: String = REFRESH_BUTTON_LABEL
) {
    companion object {
        const val REFRESH_BUTTON_LABEL: String = "Refresh attendee list"
    }
}

