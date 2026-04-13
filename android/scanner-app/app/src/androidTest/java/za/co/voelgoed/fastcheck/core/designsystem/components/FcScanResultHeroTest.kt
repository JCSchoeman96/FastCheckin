package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme

@RunWith(AndroidJUnit4::class)
class FcScanResultHeroTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersUppercaseTitleAndMessageWhenProvided() {
        composeRule.setContent {
            FastCheckTheme {
                FcScanResultHero(
                    title = "Accepted",
                    message = "Ticket check-in completed",
                    tone = StatusTone.Success,
                )
            }
        }

        composeRule.onNodeWithText("ACCEPTED").assertIsDisplayed()
        composeRule.onNodeWithText("Ticket check-in completed").assertIsDisplayed()
    }

    @Test
    fun hidesMessageWhenBlank() {
        composeRule.setContent {
            FastCheckTheme {
                FcScanResultHero(
                    title = "Duplicate",
                    message = "",
                    tone = StatusTone.Duplicate,
                )
            }
        }

        composeRule.onNodeWithText("DUPLICATE").assertIsDisplayed()
        composeRule.onAllNodesWithText("Ticket check-in completed").assertCountEquals(0)
    }
}
