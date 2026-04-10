package za.co.voelgoed.fastcheck.feature.scanning.screen

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction

data class ScanDestinationUiState(
    val activeEventLabel: String,
    val syncedAttendeeCountLabel: String,
    val lastSyncLabel: String,
    val scannerStatusChip: StatusChipUiModel,
    val scannerStatusMessage: String,
    val scannerDiagnosticMessage: String? = null,
    val attendeeStatusChip: StatusChipUiModel,
    val attendeeStatusMessage: String,
    val showCameraPreview: Boolean,
    val primaryRecoveryAction: ScanOperatorAction? = null,
    val primaryRecoveryActionLabel: String? = null,
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
