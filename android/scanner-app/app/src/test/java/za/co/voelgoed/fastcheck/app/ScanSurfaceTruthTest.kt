package za.co.voelgoed.fastcheck.app

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.shell.AppShellSupportRoute

class ScanSurfaceTruthTest {
    @Test
    fun scanSelectedWithNoSupportRouteIsActive() {
        assertThat(
            isScanSurfaceReallyActive(
                selectedDestination = AppShellDestination.Scan,
                activeSupportRoute = null
            )
        ).isTrue()
    }

    @Test
    fun scanSelectedWithSupportOverviewIsNotActive() {
        assertThat(
            isScanSurfaceReallyActive(
                selectedDestination = AppShellDestination.Scan,
                activeSupportRoute = AppShellSupportRoute.Overview
            )
        ).isFalse()
    }

    @Test
    fun scanSelectedWithDiagnosticsIsNotActive() {
        assertThat(
            isScanSurfaceReallyActive(
                selectedDestination = AppShellDestination.Scan,
                activeSupportRoute = AppShellSupportRoute.Diagnostics
            )
        ).isFalse()
    }

    @Test
    fun eventSelectedWithNoSupportRouteIsNotActive() {
        assertThat(
            isScanSurfaceReallyActive(
                selectedDestination = AppShellDestination.Event,
                activeSupportRoute = null
            )
        ).isFalse()
    }

    @Test
    fun searchSelectedWithNoSupportRouteIsNotActive() {
        assertThat(
            isScanSurfaceReallyActive(
                selectedDestination = AppShellDestination.Search,
                activeSupportRoute = null
            )
        ).isFalse()
    }
}
