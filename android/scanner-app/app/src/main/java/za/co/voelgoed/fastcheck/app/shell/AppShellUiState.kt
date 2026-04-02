package za.co.voelgoed.fastcheck.app.shell

import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction

data class AppShellUiState(
    val selectedDestination: AppShellDestination = AppShellDestination.Scan,
    val bottomDestinations: List<AppShellDestination> = AppShellDestination.bottomNavigationDestinations,
    val overflowActions: List<AppShellOverflowAction> = AppShellOverflowAction.overflowActions,
    val noticeMessage: String? = null
)
