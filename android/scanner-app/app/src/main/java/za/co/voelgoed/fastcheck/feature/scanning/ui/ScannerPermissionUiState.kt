package za.co.voelgoed.fastcheck.feature.scanning.ui

data class ScannerPermissionUiState(
    val visible: Boolean,
    val headline: String,
    val message: String,
    val requestButtonLabel: String,
    val isRequestEnabled: Boolean
)
