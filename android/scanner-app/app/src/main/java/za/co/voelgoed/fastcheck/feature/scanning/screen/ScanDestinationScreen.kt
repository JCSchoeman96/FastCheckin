package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
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
                FcStatusChip(
                    text = uiState.scannerStatusChip.text,
                    tone = uiState.scannerStatusChip.tone
                )
                Text(
                    text = uiState.scannerStatusMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
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
                    TextButton(onClick = { onOperatorAction(ScanOperatorAction.ManualSync) }) {
                        Text(text = "Sync attendee list")
                    }
                }
                if (uiState.retryUploadVisible) {
                    TextButton(onClick = { onOperatorAction(ScanOperatorAction.RetryUpload) }) {
                        Text(text = "Retry upload")
                    }
                }
                if (uiState.reloginVisible) {
                    TextButton(onClick = { onOperatorAction(ScanOperatorAction.Relogin) }) {
                        Text(text = "Re-login")
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
}
