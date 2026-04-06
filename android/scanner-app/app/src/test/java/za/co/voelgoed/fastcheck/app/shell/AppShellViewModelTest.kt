package za.co.voelgoed.fastcheck.app.shell

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction

class AppShellViewModelTest {
    @Test
    fun defaultDestinationIsScan() {
        val viewModel = AppShellViewModel()

        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Scan)
        assertThat(viewModel.uiState.value.activeSupportRoute).isNull()
    }

    @Test
    fun destinationSelectionIsDeterministicAndClosesSupport() {
        val viewModel = AppShellViewModel()

        viewModel.onOverflowActionSelected(AppShellOverflowAction.Support)
        viewModel.selectDestination(AppShellDestination.Search)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Search)
        assertThat(viewModel.uiState.value.activeSupportRoute).isNull()

        viewModel.selectDestination(AppShellDestination.Event)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Event)

        viewModel.selectDestination(AppShellDestination.Scan)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Scan)
    }

    @Test
    fun supportRemainsOverflowOnly() {
        val viewModel = AppShellViewModel()

        viewModel.onOverflowActionSelected(AppShellOverflowAction.Support)

        assertThat(viewModel.uiState.value.bottomDestinations.map { it.label })
            .doesNotContain("Support")
        assertThat(viewModel.uiState.value.overflowActions).contains(AppShellOverflowAction.Support)
        assertThat(viewModel.uiState.value.activeSupportRoute)
            .isEqualTo(AppShellSupportRoute.Overview)
    }

    @Test
    fun navigatingBackFromDiagnosticsReturnsToSupportOverview() {
        val viewModel = AppShellViewModel()

        viewModel.onOverflowActionSelected(AppShellOverflowAction.Support)
        viewModel.openDiagnostics()
        viewModel.navigateBack()

        assertThat(viewModel.uiState.value.activeSupportRoute)
            .isEqualTo(AppShellSupportRoute.Overview)
    }

    @Test
    fun logoutConfirmationShownOnlyWhenQueueDepthExists() {
        val viewModel = AppShellViewModel()

        val confirmedImmediately = viewModel.requestLogout(queueDepth = 0)
        val requiresDialog = viewModel.requestLogout(queueDepth = 3)

        assertThat(confirmedImmediately).isFalse()
        assertThat(requiresDialog).isTrue()
        assertThat(viewModel.uiState.value.logoutConfirmationQueueDepth).isEqualTo(3)
    }

    /**
     * Auth-expired re-login dismisses the destructive logout dialog before session logout,
     * so the operator is not asked to confirm as if shutdown were the goal.
     */
    @Test
    fun dismissLogoutConfirmationClearsDestructiveLogoutPromptState() {
        val viewModel = AppShellViewModel()
        viewModel.requestLogout(queueDepth = 4)
        assertThat(viewModel.uiState.value.logoutConfirmationQueueDepth).isEqualTo(4)

        viewModel.dismissLogoutConfirmation()

        assertThat(viewModel.uiState.value.logoutConfirmationQueueDepth).isNull()
    }
}
