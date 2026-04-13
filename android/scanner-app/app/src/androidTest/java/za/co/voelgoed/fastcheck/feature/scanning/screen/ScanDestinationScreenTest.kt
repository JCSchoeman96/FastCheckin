package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
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
    val composeRule = createAndroidComposeRule<ComponentActivity>()

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
                healthBanner =
                    BannerUiModel(
                        title = "Health",
                        message = "Uploads paused",
                        tone = StatusTone.Warning,
                    ),
                captureBanner = null,
            )

        render(uiState)

        composeRule.onNodeWithText("Preview").assertIsDisplayed()
        composeRule.onNodeWithText("Health").assertIsDisplayed()
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
    fun previewAndHealthBannersRenderIndependentlyFromCaptureHero() {
        val uiState =
            baseUiState(
                previewBanner =
                    BannerUiModel(
                        title = "Preview status",
                        message = "Preview still independent",
                        tone = StatusTone.Info,
                    ),
                healthBanner =
                    BannerUiModel(
                        title = "Health status",
                        message = "Health still independent",
                        tone = StatusTone.Warning,
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
        composeRule.onNodeWithText("Health status").assertIsDisplayed()
        composeRule.onNodeWithTag(ScanDestinationTestTags.CaptureResultHero).assertIsDisplayed()
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

        composeRule.onNodeWithText("Allow camera access").performClick()
        composeRule.onNodeWithText("Sync attendee list").performClick()
        composeRule.onNodeWithText("Retry upload").performClick()
        composeRule.onNodeWithText("Re-login").performClick()

        assertThat(actions).contains(ScanOperatorAction.RequestCameraAccess)
        assertThat(actions).contains(ScanOperatorAction.ManualSync)
        assertThat(actions).contains(ScanOperatorAction.RetryUpload)
        assertThat(actions).contains(ScanOperatorAction.Relogin)
    }

    private fun render(
        uiState: ScanDestinationUiState,
        onOperatorAction: (ScanOperatorAction) -> Unit = {},
    ) {
        composeRule.setContent {
            FastCheckTheme {
                ScanDestinationScreen(
                    uiState = uiState,
                    previewSurfaceHolder = ScanPreviewSurfaceHolder(),
                    onPreviewSurfaceChanged = {},
                    onOperatorAction = onOperatorAction,
                )
            }
        }
    }

    private fun baseUiState(
        scannerStatusChip: StatusChipUiModel = StatusChipUiModel("Scanner active", StatusTone.Brand),
        showCameraPreview: Boolean = false,
        previewBanner: BannerUiModel? = null,
        captureBanner: BannerUiModel? = null,
        healthBanner: BannerUiModel? = null,
        primaryRecoveryAction: ScanOperatorAction? = null,
        primaryRecoveryActionLabel: String? = null,
        manualSyncVisible: Boolean = false,
        retryUploadVisible: Boolean = false,
        reloginVisible: Boolean = false,
    ): ScanDestinationUiState =
        ScanDestinationUiState(
            activeEventLabel = "Active event: #42",
            syncedAttendeeCountLabel = "Synced attendees: 10",
            lastSyncLabel = "Last sync: now",
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = "Scanner is ready",
            scannerDiagnosticMessage = null,
            attendeeStatusChip = StatusChipUiModel("Attendee list ready", StatusTone.Success),
            attendeeStatusMessage = "Attendees are synced",
            showCameraPreview = showCameraPreview,
            primaryRecoveryAction = primaryRecoveryAction,
            primaryRecoveryActionLabel = primaryRecoveryActionLabel,
            previewBanner = previewBanner,
            captureBanner = captureBanner,
            healthBanner = healthBanner,
            queueDepthLabel = "No scans queued locally",
            uploadStateLabel = "Uploads healthy",
            manualSyncVisible = manualSyncVisible,
            retryUploadVisible = retryUploadVisible,
            reloginVisible = reloginVisible,
        )
}
