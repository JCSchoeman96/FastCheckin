package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.app.scanning.PreviewVisibilityObserver
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcDangerButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcPrimaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcScanResultHero
import za.co.voelgoed.fastcheck.core.designsystem.components.FcScannerPreviewOverlay
import za.co.voelgoed.fastcheck.core.designsystem.components.FcSecondaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction

object ScanDestinationTestTags {
    const val PreviewHost = "scan_destination_preview_host"
    const val CaptureResultHero = "scan_destination_capture_result_hero"
}

@Composable
fun ScanDestinationScreen(
    uiState: ScanDestinationUiState,
    previewSurfaceHolder: ScanPreviewSurfaceHolder,
    onPreviewSurfaceChanged: () -> Unit,
    onOperatorAction: (ScanOperatorAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val theme = MaterialTheme.fastCheck
    val spacing = theme.spacing
    val scheme = theme.colorScheme

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.xxSmall)) {
                    Text(
                        text = uiState.activeEventLabel,
                        style = theme.typography.titleMedium,
                        color = scheme.onSurface,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = uiState.syncedAttendeeCountLabel,
                        style = theme.typography.bodyMedium,
                        color = scheme.onSurface
                    )
                    Text(
                        text = uiState.lastSyncLabel,
                        style = theme.typography.bodySmall,
                        color = scheme.onSurfaceVariant
                    )
                }

                Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
                    FcStatusChip(
                        text = uiState.scannerStatusChip.text,
                        tone = uiState.scannerStatusChip.tone
                    )
                    Text(
                        text = uiState.scannerStatusMessage,
                        style = theme.typography.bodySmall,
                        color = scheme.onSurfaceVariant
                    )
                }

                uiState.scannerDiagnosticMessage?.let { diagnosticMessage ->
                    Text(
                        text = "Diagnostics: $diagnosticMessage",
                        style = theme.typography.bodySmall,
                        color = scheme.onSurfaceVariant
                    )
                }
            }
        }

        uiState.previewBanner?.let { banner ->
            FcBanner(
                title = banner.title,
                message = banner.message,
                tone = banner.tone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        if (uiState.primaryRecoveryAction != null && uiState.primaryRecoveryActionLabel != null) {
            FcPrimaryButton(
                text = uiState.primaryRecoveryActionLabel,
                onClick = { onOperatorAction(uiState.primaryRecoveryAction) },
                modifier = Modifier.fillMaxWidth()
            )
        }

        if (uiState.showCameraPreview) {
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Box(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .testTag(ScanDestinationTestTags.PreviewHost)
                ) {
                    PreviewSurface(
                        previewSurfaceHolder = previewSurfaceHolder,
                        onPreviewSurfaceChanged = onPreviewSurfaceChanged,
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .height(260.dp)
                    )

                    FcScannerPreviewOverlay(
                        statusLabel = uiState.scannerStatusChip.text,
                        statusTone = uiState.scannerStatusChip.tone,
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .height(260.dp)
                    )
                }
            }
        }

        uiState.captureBanner?.let { banner ->
            val heroTitle = banner.title?.takeIf { it.isNotBlank() } ?: banner.message
            val heroMessage =
                banner.title
                    ?.takeIf { it.isNotBlank() }
                    ?.let { banner.message.takeIf { message -> message.isNotBlank() } }

            FcScanResultHero(
                title = heroTitle,
                message = heroMessage,
                tone = banner.tone,
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .testTag(ScanDestinationTestTags.CaptureResultHero),
            )
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
                Text(
                    text = uiState.admissionSectionTitle,
                    style = theme.typography.titleMedium,
                    color = scheme.onSurface,
                    fontWeight = FontWeight.SemiBold
                )
                Column(verticalArrangement = Arrangement.spacedBy(spacing.xxSmall)) {
                    FcStatusChip(
                        text = uiState.admissionStatusChip.text,
                        tone = uiState.admissionStatusChip.tone
                    )
                    Text(
                        text = uiState.admissionStatusMessage,
                        style = theme.typography.bodyMedium,
                        color = scheme.onSurfaceVariant
                    )
                }
            }
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            val hasQueueUploadActions =
                uiState.manualSyncVisible || uiState.retryUploadVisible || uiState.reloginVisible

            Column(verticalArrangement = Arrangement.spacedBy(spacing.medium)) {
                Text(
                    text = uiState.queueUploadSectionTitle,
                    style = theme.typography.titleMedium,
                    color = scheme.onSurface,
                    fontWeight = FontWeight.SemiBold
                )

                Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
                    Text(
                        text = uiState.queueDepthLabel,
                        style = theme.typography.bodyMedium,
                        color = scheme.onSurface
                    )
                    FcStatusChip(
                        text = uiState.queueUploadStatusChip.text,
                        tone = uiState.queueUploadStatusChip.tone
                    )
                    Text(
                        text = uiState.queueUploadStatusMessage,
                        style = theme.typography.bodySmall,
                        color = scheme.onSurfaceVariant
                    )
                }

                if (hasQueueUploadActions) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(spacing.xSmall)
                    ) {
                        Text(
                            text = "Actions",
                            style = theme.typography.labelMedium,
                            color = scheme.onSurfaceVariant,
                            fontWeight = FontWeight.SemiBold
                        )
                        if (uiState.manualSyncVisible) {
                            FcSecondaryButton(
                                text = "Sync attendee list",
                                onClick = { onOperatorAction(ScanOperatorAction.ManualSync) },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        if (uiState.retryUploadVisible) {
                            FcSecondaryButton(
                                text = "Retry upload",
                                onClick = { onOperatorAction(ScanOperatorAction.RetryUpload) },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                        if (uiState.reloginVisible) {
                            FcDangerButton(
                                text = "Re-login",
                                onClick = { onOperatorAction(ScanOperatorAction.Relogin) },
                                modifier = Modifier.fillMaxWidth()
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun PreviewSurface(
    previewSurfaceHolder: ScanPreviewSurfaceHolder,
    onPreviewSurfaceChanged: () -> Unit,
    modifier: Modifier = Modifier
) {
    var attachedPreviewView by remember { mutableStateOf<PreviewView?>(null) }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            PreviewView(context).also {
                attachedPreviewView = it
                previewSurfaceHolder.attach(it)
                onPreviewSurfaceChanged()
            }
        },
        update = {
            // Keep holder attachment stable across recompositions.
            if (attachedPreviewView !== it) {
                attachedPreviewView = it
                previewSurfaceHolder.attach(it)
                onPreviewSurfaceChanged()
            }
        }
    )

    DisposableEffect(previewSurfaceHolder, onPreviewSurfaceChanged) {
        onDispose {
            attachedPreviewView?.let(previewSurfaceHolder::detach)
            onPreviewSurfaceChanged()
        }
    }

    DisposableEffect(attachedPreviewView) {
        val view = attachedPreviewView ?: return@DisposableEffect onDispose {}
        val observer = PreviewVisibilityObserver(onBecameVisible = onPreviewSurfaceChanged)

        fun evaluateNow() {
            val isVisible = view.isAttachedToWindow &&
                view.visibility == android.view.View.VISIBLE && view.isShown
            observer.onVisibilityEvaluated(isVisible)
        }

        val listener = android.view.ViewTreeObserver.OnGlobalLayoutListener { evaluateNow() }
        view.viewTreeObserver.addOnGlobalLayoutListener(listener)

        evaluateNow()

        onDispose {
            view.viewTreeObserver.removeOnGlobalLayoutListener(listener)
        }
    }
}
