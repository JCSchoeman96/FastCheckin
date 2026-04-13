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
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme

@RunWith(AndroidJUnit4::class)
class FcScanResultDetailsCardTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersNothingWhenItemsEmpty() {
        composeRule.setContent {
            FastCheckTheme {
                FcScanResultDetailsCard(items = emptyList())
            }
        }

        composeRule.onAllNodesWithText("ORIGINAL ENTRY METADATA").assertCountEquals(0)
    }

    @Test
    fun rendersTitleAndAllRowsWhenItemsProvided() {
        composeRule.setContent {
            FastCheckTheme {
                FcScanResultDetailsCard(
                    items =
                        listOf(
                            FcScanResultDetailItem(label = "Operator", value = "Scanner 2"),
                            FcScanResultDetailItem(label = "Time", value = "10:30"),
                        ),
                )
            }
        }

        composeRule.onNodeWithText("ORIGINAL ENTRY METADATA").assertIsDisplayed()
        composeRule.onNodeWithText("OPERATOR").assertIsDisplayed()
        composeRule.onNodeWithText("Scanner 2").assertIsDisplayed()
        composeRule.onNodeWithText("TIME").assertIsDisplayed()
        composeRule.onNodeWithText("10:30").assertIsDisplayed()
    }
}
