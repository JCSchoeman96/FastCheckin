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
                AppShellOverflowAction.Support,
                AppShellOverflowAction.Logout
            )
            .inOrder()
    }

    @Test
    fun supportNeverAppearsAsATabLabel() {
        assertThat(AppShellDestination.bottomNavigationDestinations.map { it.label })
            .doesNotContain("Support")
    }
}
