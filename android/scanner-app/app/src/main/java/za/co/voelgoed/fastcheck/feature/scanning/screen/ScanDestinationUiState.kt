package za.co.voelgoed.fastcheck.feature.scanning.screen

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction

data class ScanDestinationUiState(
    val scannerOverlayTitle: String,
    val scannerOverlayEventLabel: String,
    val scannerOverlaySyncLabel: String,
    val syncedAttendeeCountLabel: String,
    val scannerStatusChip: StatusChipUiModel,
    val scannerStatusMessage: String,
    val scannerDiagnosticLabel: String? = null,
    val scannerDiagnosticMessage: String? = null,
    val admissionSectionTitle: String,
    val admissionStatusChip: StatusChipUiModel,
    val admissionStatusVerdict: String,
    val admissionStatusDetail: String,
    val showCameraPreview: Boolean,
    val primaryRecoveryAction: ScanOperatorAction? = null,
    val primaryRecoveryActionLabel: String? = null,
    val previewBanner: BannerUiModel? = null,
    val captureBanner: BannerUiModel? = null,
    val queueUploadSectionTitle: String,
    val queueDepthLabel: String,
    val queueUploadStatusChip: StatusChipUiModel,
    val queueUploadStatusVerdict: String,
    val queueUploadStatusDetail: String,
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
