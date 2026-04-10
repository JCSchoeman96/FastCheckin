package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.app.scanning.PreviewVisibilityObserver
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcDangerButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcPrimaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcSecondaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction

@Composable
fun ScanDestinationScreen(
    uiState: ScanDestinationUiState,
    previewSurfaceHolder: ScanPreviewSurfaceHolder,
    onPreviewSurfaceChanged: () -> Unit,
    onOperatorAction: (ScanOperatorAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Scan",
                    style = MaterialTheme.typography.headlineSmall
                )
                Text(
                    text = uiState.activeEventLabel,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = uiState.syncedAttendeeCountLabel,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = uiState.lastSyncLabel,
                    style = MaterialTheme.typography.bodyMedium
                )
                FcStatusChip(
                    text = uiState.scannerStatusChip.text,
                    tone = uiState.scannerStatusChip.tone
                )
                Text(
                    text = uiState.scannerStatusMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
                uiState.scannerDiagnosticMessage?.let { diagnosticMessage ->
                    Text(
                        text = "Diagnostics: $diagnosticMessage",
                        style = MaterialTheme.typography.bodySmall
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
                PreviewSurface(
                    previewSurfaceHolder = previewSurfaceHolder,
                    onPreviewSurfaceChanged = onPreviewSurfaceChanged,
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .height(260.dp)
                )
            }
        }

        uiState.captureBanner?.let { banner ->
            FcBanner(
                title = banner.title,
                message = banner.message,
                tone = banner.tone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Attendee readiness",
                    style = MaterialTheme.typography.titleMedium
                )
                FcStatusChip(
                    text = uiState.attendeeStatusChip.text,
                    tone = uiState.attendeeStatusChip.tone
                )
                Text(
                    text = uiState.attendeeStatusMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }

        uiState.healthBanner?.let { banner ->
            FcBanner(
                title = banner.title,
                message = banner.message,
                tone = banner.tone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Scan health",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = uiState.queueDepthLabel,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = uiState.uploadStateLabel,
                    style = MaterialTheme.typography.bodyMedium
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

@Composable
private fun PreviewSurface(
    previewSurfaceHolder: ScanPreviewSurfaceHolder,
    onPreviewSurfaceChanged: () -> Unit,
    modifier: Modifier = Modifier
) {
    var currentPreviewView by remember { mutableStateOf<PreviewView?>(null) }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            PreviewView(context).also {
                currentPreviewView = it
                previewSurfaceHolder.attach(it)
                onPreviewSurfaceChanged()
            }
        },
        update = {
            currentPreviewView = it
            previewSurfaceHolder.attach(it)
            onPreviewSurfaceChanged()
        }
    )

    DisposableEffect(previewSurfaceHolder, onPreviewSurfaceChanged, currentPreviewView) {
        onDispose {
            currentPreviewView?.let(previewSurfaceHolder::detach)
            onPreviewSurfaceChanged()
        }
    }

    DisposableEffect(currentPreviewView) {
        val view = currentPreviewView ?: return@DisposableEffect onDispose {}
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
