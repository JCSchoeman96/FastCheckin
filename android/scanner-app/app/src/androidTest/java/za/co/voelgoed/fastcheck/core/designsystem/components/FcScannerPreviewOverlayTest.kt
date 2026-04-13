package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme

@RunWith(AndroidJUnit4::class)
class FcScannerPreviewOverlayTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersUppercaseStatusLabelWhenProvided() {
        composeRule.setContent {
            FastCheckTheme {
                FcScannerPreviewOverlay(
                    statusLabel = "Camera ready",
                    statusTone = StatusTone.Info,
                )
            }
        }

        composeRule.onNodeWithText("CAMERA READY").assertIsDisplayed()
    }

    @Test
    fun hidesStatusLabelWhenBlank() {
        val statusLabel = mutableStateOf("Camera ready")

        composeRule.setContent {
            FastCheckTheme {
                FcScannerPreviewOverlay(
                    statusLabel = statusLabel.value,
                    statusTone = StatusTone.Info,
                )
            }
        }

        composeRule.onNodeWithText("CAMERA READY").assertIsDisplayed()
        composeRule.runOnUiThread {
            statusLabel.value = " "
        }
        composeRule.onAllNodesWithText("CAMERA READY").assertCountEquals(0)
    }

    @Test
    fun reticleVisibilityTogglesWithShowReticle() {
        val showReticle = mutableStateOf(true)

        composeRule.setContent {
            FastCheckTheme {
                FcScannerPreviewOverlay(showReticle = showReticle.value)
            }
        }
        composeRule.onNodeWithTag(FcScannerPreviewOverlayTestTags.Reticle).assertIsDisplayed()

        composeRule.runOnUiThread {
            showReticle.value = false
        }
        composeRule.onAllNodesWithTag(FcScannerPreviewOverlayTestTags.Reticle).assertCountEquals(0)
    }
}
