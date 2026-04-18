package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction

@RunWith(AndroidJUnit4::class)
class ScanDestinationScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun captureHeroRendersWhenCaptureBannerExists() {
        val uiState =
            baseUiState(
                captureBanner =
                    BannerUiModel(
                        title = "Accepted",
                        message = "Ticket is valid",
                        tone = StatusTone.Success,
                    ),
            )

        render(uiState)

        composeRule.onNodeWithTag(ScanDestinationTestTags.CaptureResultHero).assertIsDisplayed()
        composeRule.onNodeWithText("ACCEPTED").assertIsDisplayed()
        composeRule.onNodeWithText("Ticket is valid").assertIsDisplayed()
    }

    @Test
    fun captureHeroUsesMessageAsTitleWhenBannerTitleMissing() {
        val uiState =
            baseUiState(
                captureBanner =
                    BannerUiModel(
                        title = null,
                        message = "Queued locally",
                        tone = StatusTone.Brand,
                    ),
            )

        render(uiState)

        composeRule.onNodeWithTag(ScanDestinationTestTags.CaptureResultHero).assertIsDisplayed()
        composeRule.onNodeWithText("QUEUED LOCALLY").assertIsDisplayed()
        composeRule.onAllNodesWithText("Queued locally").assertCountEquals(0)
    }

    @Test
    fun captureHeroIsAbsentWhenCaptureBannerMissingEvenIfOtherBannersPresent() {
        val uiState =
            baseUiState(
                previewBanner =
                    BannerUiModel(
                        title = "Preview",
                        message = "Camera is loading",
                        tone = StatusTone.Info,
                    ),
                captureBanner = null,
            )

        render(uiState)

        composeRule.onNodeWithText("Preview").assertIsDisplayed()
        composeRule.onAllNodesWithTag(ScanDestinationTestTags.CaptureResultHero).assertCountEquals(0)
    }

    @Test
    fun previewOverlayContainerAndStatusRenderWhenPreviewShown() {
        val scannerStatusText = "Camera ready"
        val uiState =
            baseUiState(
                showCameraPreview = true,
                scannerStatusChip = StatusChipUiModel(text = scannerStatusText, tone = StatusTone.Info),
            )

        render(uiState)

        composeRule.onNodeWithTag(ScanDestinationTestTags.PreviewHost).assertIsDisplayed()
        composeRule.onNodeWithText(scannerStatusText.uppercase()).assertIsDisplayed()
    }

    @Test
    fun previewContainerIsHiddenWhenPreviewDisabled() {
        render(baseUiState(showCameraPreview = false))
        composeRule.onAllNodesWithTag(ScanDestinationTestTags.PreviewHost).assertCountEquals(0)
    }

    @Test
    fun previewBannerRendersIndependentlyFromCaptureHero() {
        val uiState =
            baseUiState(
                previewBanner =
                    BannerUiModel(
                        title = "Preview status",
                        message = "Preview still independent",
                        tone = StatusTone.Info,
                    ),
                captureBanner =
                    BannerUiModel(
                        title = "Success",
                        message = "Captured",
                        tone = StatusTone.Success,
                    ),
            )

        render(uiState)

        composeRule.onNodeWithText("Preview status").assertIsDisplayed()
        composeRule.onNodeWithTag(ScanDestinationTestTags.CaptureResultHero).assertIsDisplayed()
    }

    @Test
    fun scanBodyUsesTruthfulAdmissionAndQueueUploadSections() {
        render(
            baseUiState(
                admissionStatusChip = StatusChipUiModel("Admission ready", StatusTone.Success),
                admissionStatusVerdict = "Ready for admission",
                admissionStatusDetail = "Recent attendee data is available for this event.",
                queueUploadStatusChip = StatusChipUiModel("Uploads paused offline", StatusTone.Offline),
                queueUploadStatusVerdict = "Queued scans waiting",
                queueUploadStatusDetail = "Uploads will retry automatically when connectivity returns.",
            )
        )

        composeRule.onNodeWithText("Admission readiness").assertIsDisplayed()
        composeRule.onNodeWithText("Admission ready").assertIsDisplayed()
        composeRule.onNodeWithText("Ready for admission").assertIsDisplayed()
        composeRule.onNodeWithText("Recent attendee data is available for this event.").assertIsDisplayed()
        composeRule.onNodeWithText("Queue & upload").assertIsDisplayed()
        composeRule.onNodeWithText("Uploads paused offline").assertIsDisplayed()
        composeRule.onNodeWithText("Queued scans waiting").assertIsDisplayed()
        composeRule.onNodeWithText("Uploads will retry automatically when connectivity returns.").assertIsDisplayed()
        composeRule.onAllNodesWithText("Actions").assertCountEquals(0)
        composeRule.onAllNodesWithText("Attendee readiness").assertCountEquals(0)
        composeRule.onAllNodesWithText("Scan health").assertCountEquals(0)
    }

    @Test
    fun topSummaryUsesCompactFactsAndFriendlySyncCopy() {
        render(
            baseUiState(
                factLabels = listOf("Synced attendees: 10", "Last sync 08:50"),
            )
        )

        composeRule.onNodeWithText("Active event: #42").assertIsDisplayed()
        composeRule.onNodeWithText("Synced attendees: 10").assertIsDisplayed()
        composeRule.onNodeWithText("Last sync 08:50").assertIsDisplayed()
        composeRule.onAllNodesWithText("Last sync: 2026-03-13T08:50:00Z").assertCountEquals(0)
    }

    @Test
    fun diagnosticsAreHiddenWhenMissing() {
        render(baseUiState())

        composeRule.onAllNodesWithText("Diagnostics").assertCountEquals(0)
    }

    @Test
    fun diagnosticsRenderWhenProvided() {
        render(
            baseUiState(
                scannerDiagnosticLabel = "Diagnostics",
                scannerDiagnosticMessage = "Camera preview is not responding.",
            )
        )

        composeRule.onNodeWithText("Diagnostics").assertIsDisplayed()
        composeRule.onNodeWithText("Camera preview is not responding.").assertIsDisplayed()
    }

    @Test
    fun actionsGroupIsHiddenWhenNoRecoveryActionIsVisible() {
        render(baseUiState())

        composeRule.onAllNodesWithText("Actions").assertCountEquals(0)
    }

    @Test
    fun manualSyncActionRendersWithoutOtherActions() {
        render(baseUiState(manualSyncVisible = true))

        composeRule.onNodeWithText("Actions").assertIsDisplayed()
        composeRule.onNodeWithText("Sync attendee list").performScrollTo().assertIsDisplayed()
        composeRule.onAllNodesWithText("Retry upload").assertCountEquals(0)
        composeRule.onAllNodesWithText("Re-login").assertCountEquals(0)
    }

    @Test
    fun narrowLargeFontSummaryKeepsCriticalFactsVisible() {
        render(
            uiState =
                baseUiState(
                    factLabels = listOf("Synced attendees: 1234", "Last sync 13 Mar 08:50"),
                    manualSyncVisible = true,
                ),
            modifier = Modifier.width(240.dp),
            fontScale = 1.45f,
        )

        composeRule.onNodeWithText("Active event: #42").assertIsDisplayed()
        composeRule.onNodeWithText("Synced attendees: 1234").assertIsDisplayed()
        composeRule.onNodeWithText("Last sync 13 Mar 08:50").assertIsDisplayed()
        composeRule.onNodeWithText("Admission readiness").assertIsDisplayed()
        composeRule.onNodeWithText("Queue & upload").assertIsDisplayed()
        composeRule.onNodeWithText("Sync attendee list").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun actionButtonsRenderAndDispatchAccordingToUiStateFlags() {
        val actions = mutableListOf<ScanOperatorAction>()
        val uiState =
            baseUiState(
                primaryRecoveryAction = ScanOperatorAction.RequestCameraAccess,
                primaryRecoveryActionLabel = "Allow camera access",
                manualSyncVisible = true,
                retryUploadVisible = true,
                reloginVisible = true,
            )

        render(uiState, actions::add)

        composeRule.onNodeWithText("Actions").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Allow camera access").performScrollTo().performClick()
        composeRule.onNodeWithText("Sync attendee list").performScrollTo().performClick()
        composeRule.onNodeWithText("Retry upload").performScrollTo().performClick()
        composeRule.onNodeWithText("Re-login").performScrollTo().performClick()

        assertThat(actions).contains(ScanOperatorAction.RequestCameraAccess)
        assertThat(actions).contains(ScanOperatorAction.ManualSync)
        assertThat(actions).contains(ScanOperatorAction.RetryUpload)
        assertThat(actions).contains(ScanOperatorAction.Relogin)
    }

    private fun render(
        uiState: ScanDestinationUiState,
        onOperatorAction: (ScanOperatorAction) -> Unit = {},
        modifier: Modifier = Modifier,
        fontScale: Float = 1.0f,
    ) {
        composeRule.setContent {
            FastCheckTheme {
                val density = LocalDensity.current
                CompositionLocalProvider(
                    LocalDensity provides Density(density.density, fontScale)
                ) {
                    Box(modifier = modifier.verticalScroll(rememberScrollState())) {
                        ScanDestinationScreen(
                            uiState = uiState,
                            previewSurfaceHolder = ScanPreviewSurfaceHolder(),
                            onPreviewSurfaceChanged = {},
                            onOperatorAction = onOperatorAction,
                        )
                    }
                }
            }
        }
    }

    private fun baseUiState(
        factLabels: List<String> = listOf("Synced attendees: 10", "Last sync 08:50"),
        scannerStatusChip: StatusChipUiModel = StatusChipUiModel("Scanner active", StatusTone.Brand),
        admissionStatusChip: StatusChipUiModel = StatusChipUiModel("Attendee list ready", StatusTone.Success),
        admissionStatusVerdict: String = "Ready for admission",
        admissionStatusDetail: String = "Recent attendee data is available for this event.",
        queueUploadStatusChip: StatusChipUiModel = StatusChipUiModel("No upload backlog", StatusTone.Neutral),
        queueUploadStatusVerdict: String = "Upload queue clear",
        queueUploadStatusDetail: String = "New scans will still be saved locally before upload.",
        scannerDiagnosticLabel: String? = null,
        scannerDiagnosticMessage: String? = null,
        showCameraPreview: Boolean = false,
        previewBanner: BannerUiModel? = null,
        captureBanner: BannerUiModel? = null,
        primaryRecoveryAction: ScanOperatorAction? = null,
        primaryRecoveryActionLabel: String? = null,
        manualSyncVisible: Boolean = false,
        retryUploadVisible: Boolean = false,
        reloginVisible: Boolean = false,
    ): ScanDestinationUiState =
        ScanDestinationUiState(
            activeEventLabel = "Active event: #42",
            factLabels = factLabels,
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = "Scanner is ready",
            scannerDiagnosticLabel = scannerDiagnosticLabel,
            scannerDiagnosticMessage = scannerDiagnosticMessage,
            admissionSectionTitle = "Admission readiness",
            admissionStatusChip = admissionStatusChip,
            admissionStatusVerdict = admissionStatusVerdict,
            admissionStatusDetail = admissionStatusDetail,
            showCameraPreview = showCameraPreview,
            primaryRecoveryAction = primaryRecoveryAction,
            primaryRecoveryActionLabel = primaryRecoveryActionLabel,
            previewBanner = previewBanner,
            captureBanner = captureBanner,
            queueUploadSectionTitle = "Queue & upload",
            queueDepthLabel = "No scans queued locally",
            queueUploadStatusChip = queueUploadStatusChip,
            queueUploadStatusVerdict = queueUploadStatusVerdict,
            queueUploadStatusDetail = queueUploadStatusDetail,
            manualSyncVisible = manualSyncVisible,
            retryUploadVisible = retryUploadVisible,
            reloginVisible = reloginVisible,
        )
}
