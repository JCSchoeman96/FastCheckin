package za.co.voelgoed.fastcheck.feature.scanning.screen

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class ScanDestinationUiState(
    val scannerStatusChip: StatusChipUiModel,
    val scannerStatusMessage: String,
    val attendeeStatusChip: StatusChipUiModel,
    val attendeeStatusMessage: String,
    val showCameraPreview: Boolean,
    val previewBanner: BannerUiModel? = null,
    val captureBanner: BannerUiModel? = null,
    val healthBanner: BannerUiModel? = null,
    val queueDepthLabel: String,
    val uploadStateLabel: String,
    val manualSyncVisible: Boolean,
    val retryUploadVisible: Boolean,
    val reloginVisible: Boolean
)

data class StatusChipUiModel(
    val text: String,
    val tone: StatusTone
)

data class BannerUiModel(
    val message: String,
    val tone: StatusTone,
    val title: String? = null
)
