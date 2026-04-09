package za.co.voelgoed.fastcheck.app.shell

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.annotation.StringRes
import za.co.voelgoed.fastcheck.R
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AuthenticatedShellScreen(
    uiState: AppShellUiState,
    onDestinationSelected: (AppShellDestination) -> Unit,
    onOverflowActionSelected: (AppShellOverflowAction) -> Unit,
    onNavigateBack: () -> Unit,
    onLogoutConfirmationDismissed: () -> Unit,
    onLogoutConfirmed: () -> Unit,
    scanContent: @Composable () -> Unit,
    searchContent: @Composable () -> Unit,
    eventContent: @Composable () -> Unit,
    supportOverviewContent: @Composable () -> Unit,
    diagnosticsContent: @Composable () -> Unit,
    modifier: Modifier = Modifier
) {
    FastCheckTheme {
        val activeSupportRoute = uiState.activeSupportRoute
        val topBarTitle =
            activeSupportRoute?.title
                ?: stringResource(uiState.selectedDestination.topBarTitleRes())
        var overflowExpanded by remember { mutableStateOf(false) }

        if (activeSupportRoute != null) {
            BackHandler(onBack = onNavigateBack)
        }

        Scaffold(
            modifier = modifier,
            topBar = {
                TopAppBar(
                    title = {
                        ShellTopAppBarTitle(title = topBarTitle)
                    },
                    navigationIcon = {
                        if (activeSupportRoute != null) {
                            TextButton(onClick = onNavigateBack) {
                                Text(text = "Back")
                            }
                        }
                    },
                    actions = {
                        if (activeSupportRoute == null) {
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
                    }
                )
            },
            bottomBar = {
                NavigationBar {
                    uiState.bottomDestinations.forEach { destination ->
                        NavigationBarItem(
                            selected = destination == uiState.selectedDestination,
                            onClick = { onDestinationSelected(destination) },
                            icon = {
                                Icon(
                                    imageVector = destination.icon,
                                    contentDescription = null
                                )
                            },
                            label = { Text(text = destination.label) }
                        )
                    }
                }
            }
        ) { innerPadding ->
            ShellContent(
                uiState = uiState,
                contentPadding = innerPadding,
                scanContent = scanContent,
                searchContent = searchContent,
                eventContent = eventContent,
                supportOverviewContent = supportOverviewContent,
                diagnosticsContent = diagnosticsContent
            )
        }

        uiState.logoutConfirmationQueueDepth?.let { queueDepth ->
            AlertDialog(
                onDismissRequest = onLogoutConfirmationDismissed,
                title = { Text(text = "Queued scans still need upload") },
                text = {
                    Text(
                        text =
                            when (queueDepth) {
                                1 -> "1 scan is still queued locally. It stays on this device and needs a later login before upload can continue."
                                else -> "$queueDepth scans are still queued locally. They stay on this device and need a later login before upload can continue."
                            }
                    )
                },
                confirmButton = {
                    TextButton(onClick = onLogoutConfirmed) {
                        Text(text = "Log out")
                    }
                },
                dismissButton = {
                    TextButton(onClick = onLogoutConfirmationDismissed) {
                        Text(text = "Stay signed in")
                    }
                }
            )
        }
    }
}

@Composable
private fun ShellTopAppBarTitle(
    title: String,
    modifier: Modifier = Modifier
) {
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val showLogo = maxWidth >= 180.dp

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(if (showLogo) 8.dp else 0.dp)
        ) {
            if (showLogo) {
                Image(
                    painter = painterResource(id = R.drawable.fastcheck_logo),
                    contentDescription = null,
                    contentScale = ContentScale.Fit,
                    modifier =
                        Modifier
                            .height(16.dp)
                            .widthIn(max = 64.dp)
                            .alpha(0.84f)
                )
            }
            Text(
                text = title,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f)
            )
        }
    }
}

@Composable
private fun ShellContent(
    uiState: AppShellUiState,
    contentPadding: PaddingValues,
    scanContent: @Composable () -> Unit,
    searchContent: @Composable () -> Unit,
    eventContent: @Composable () -> Unit,
    supportOverviewContent: @Composable () -> Unit,
    diagnosticsContent: @Composable () -> Unit
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
        when (uiState.activeSupportRoute) {
            AppShellSupportRoute.Overview -> supportOverviewContent()
            AppShellSupportRoute.Diagnostics -> diagnosticsContent()
            null ->
                when (uiState.selectedDestination) {
                    AppShellDestination.Scan -> scanContent()
                    AppShellDestination.Search -> searchContent()
                    AppShellDestination.Event -> eventContent()
                }
        }
    }
}

@StringRes
private fun AppShellDestination.topBarTitleRes(): Int =
    when (this) {
        AppShellDestination.Scan -> R.string.top_bar_title_scan
        AppShellDestination.Search -> R.string.top_bar_title_search
        AppShellDestination.Event -> R.string.top_bar_title_event
    }
