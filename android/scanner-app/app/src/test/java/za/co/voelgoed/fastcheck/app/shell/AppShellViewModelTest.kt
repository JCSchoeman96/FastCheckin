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
    }

    @Test
    fun destinationSelectionIsDeterministic() {
        val viewModel = AppShellViewModel()

        viewModel.selectDestination(AppShellDestination.Search)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Search)

        viewModel.selectDestination(AppShellDestination.Event)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Event)

        viewModel.selectDestination(AppShellDestination.Scan)
        assertThat(viewModel.uiState.value.selectedDestination).isEqualTo(AppShellDestination.Scan)
    }

    @Test
    fun diagnosticsRemainsOverflowOnly() {
        val viewModel = AppShellViewModel()

        viewModel.onOverflowActionSelected(AppShellOverflowAction.Diagnostics)

        assertThat(viewModel.uiState.value.bottomDestinations.map { it.label })
            .doesNotContain("Diagnostics")
        assertThat(viewModel.uiState.value.overflowActions).contains(AppShellOverflowAction.Diagnostics)
        assertThat(viewModel.uiState.value.noticeMessage).contains("Diagnostics remains secondary")
    }
}
