package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
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
    val composeRule = createComposeRule()

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
        val message = mutableStateOf("Duplicate capture blocked")

        composeRule.setContent {
            FastCheckTheme {
                FcScanResultHero(
                    title = "Duplicate",
                    message = message.value,
                    tone = StatusTone.Duplicate,
                )
            }
        }

        composeRule.onNodeWithText("DUPLICATE").assertIsDisplayed()
        composeRule.onNodeWithText("Duplicate capture blocked").assertIsDisplayed()
        composeRule.runOnUiThread {
            message.value = " "
        }
        composeRule.onAllNodesWithText("Duplicate capture blocked").assertCountEquals(0)
    }
}
