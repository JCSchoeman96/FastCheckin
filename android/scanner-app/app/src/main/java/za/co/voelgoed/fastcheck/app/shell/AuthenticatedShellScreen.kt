package za.co.voelgoed.fastcheck.app.shell

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AuthenticatedShellScreen(
    uiState: AppShellUiState,
    onDestinationSelected: (AppShellDestination) -> Unit,
    onOverflowActionSelected: (AppShellOverflowAction) -> Unit,
    onNoticeDismissed: () -> Unit,
    scanContent: @Composable () -> Unit,
    modifier: Modifier = Modifier
) {
    FastCheckTheme {
        var overflowExpanded by remember { mutableStateOf(false) }

        Scaffold(
            modifier = modifier,
            topBar = {
                TopAppBar(
                    title = { Text(text = "FastCheck Shell") },
                    actions = {
                        TextButton(onClick = { overflowExpanded = true }) {
                            Text(text = "More")
                        }
                        DropdownMenu(
                            expanded = overflowExpanded,
                            onDismissRequest = { overflowExpanded = false }
                        ) {
                            uiState.overflowActions.forEach { action ->
                                DropdownMenuItem(
                                    text = { Text(action.label) },
                                    onClick = {
                                        overflowExpanded = false
                                        onOverflowActionSelected(action)
                                    }
                                )
                            }
                        }
                    }
                )
            },
            bottomBar = {
                NavigationBar {
                    uiState.bottomDestinations.forEach { destination ->
                        NavigationBarItem(
                            selected = destination == uiState.selectedDestination,
                            onClick = { onDestinationSelected(destination) },
                            icon = { Text(text = destination.compactLabel) },
                            label = { Text(text = destination.label) }
                        )
                    }
                }
            }
        ) { innerPadding ->
            ShellContent(
                uiState = uiState,
                contentPadding = innerPadding,
                onNoticeDismissed = onNoticeDismissed,
                scanContent = scanContent
            )
        }
    }
}

@Composable
private fun ShellContent(
    uiState: AppShellUiState,
    contentPadding: PaddingValues,
    onNoticeDismissed: () -> Unit,
    scanContent: @Composable () -> Unit,
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier =
            Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .padding(horizontal = spacing.medium, vertical = spacing.small),
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        uiState.noticeMessage?.let { notice ->
            FcBanner(
                title = "Overflow placeholder",
                message = notice,
                tone = StatusTone.Neutral,
                modifier = Modifier.fillMaxWidth()
            )
            TextButton(onClick = onNoticeDismissed) {
                Text(text = "Dismiss")
            }
        }

        when (uiState.selectedDestination) {
            AppShellDestination.Scan -> scanContent()
            AppShellDestination.Search -> SearchStubScreen(modifier = Modifier.fillMaxWidth())
            AppShellDestination.Event -> EventStubScreen(modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
fun ScanBridgePlaceholder(modifier: Modifier = Modifier) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcBanner(
            title = "Scan bridge placeholder",
            message = "Phase 9B establishes the authenticated shell only. Phase 9C will mount the existing operator runtime here as a temporary bridge.",
            tone = StatusTone.Warning,
            modifier = Modifier.fillMaxWidth()
        )
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Why this is empty",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "The shell is now the permanent top-level runtime shape. The current XML operator controls stay out of this PR so the legacy bridge can be extracted cleanly in the next slice."
                )
            }
        }
    }
}
