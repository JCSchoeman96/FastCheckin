package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme

@RunWith(AndroidJUnit4::class)
class FcScanResultActionsRowTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersPrimaryOnlyWhenSecondaryMissing() {
        var primaryClicks = 0

        composeRule.setContent {
            FastCheckTheme {
                FcScanResultActionsRow(
                    primaryText = "Continue",
                    onPrimaryClick = { primaryClicks += 1 },
                )
            }
        }

        composeRule.onNodeWithText("Continue").assertIsDisplayed().performClick()
        composeRule.onAllNodesWithText("Retry").assertCountEquals(0)
        assertThat(primaryClicks).isEqualTo(1)
    }

    @Test
    fun rendersPrimaryAndSecondaryAndDispatchesBothCallbacks() {
        var primaryClicks = 0
        var secondaryClicks = 0

        composeRule.setContent {
            FastCheckTheme {
                FcScanResultActionsRow(
                    primaryText = "Continue",
                    onPrimaryClick = { primaryClicks += 1 },
                    secondaryText = "Retry",
                    onSecondaryClick = { secondaryClicks += 1 },
                )
            }
        }

        composeRule.onNodeWithText("Retry").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("Continue").assertIsDisplayed().performClick()
        assertThat(secondaryClicks).isEqualTo(1)
        assertThat(primaryClicks).isEqualTo(1)
    }
}
