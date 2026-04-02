package za.co.voelgoed.fastcheck.app.navigation

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class AppShellDestinationTest {
    @Test
    fun bottomNavigationOrderRemainsScanSearchEvent() {
        assertThat(AppShellDestination.bottomNavigationDestinations)
            .containsExactly(
                AppShellDestination.Scan,
                AppShellDestination.Search,
                AppShellDestination.Event
            )
            .inOrder()
    }

    @Test
    fun overflowActionsAreNotBottomNavigationDestinations() {
        assertThat(AppShellDestination.bottomNavigationDestinations)
            .containsExactly(
                AppShellDestination.Scan,
                AppShellDestination.Search,
                AppShellDestination.Event
            )
            .inOrder()
        assertThat(AppShellOverflowAction.overflowActions)
            .containsExactly(
                AppShellOverflowAction.Preferences,
                AppShellOverflowAction.Permissions,
                AppShellOverflowAction.Diagnostics,
                AppShellOverflowAction.Logout
            )
            .inOrder()
    }

    @Test
    fun diagnosticsNeverAppearsAsATabLabel() {
        assertThat(AppShellDestination.bottomNavigationDestinations.map { it.label })
            .doesNotContain("Diagnostics")
    }
}
