package za.co.voelgoed.fastcheck.core.connectivity

import kotlinx.coroutines.flow.StateFlow

/**
 * Event-driven connectivity boundary.
 *
 * The monitor must expose a current state immediately (seeded from a snapshot)
 * and then update via platform callbacks. "Online" should reflect a usable
 * internet connection, not merely a network being present.
 */
interface ConnectivityMonitor {
    val isOnline: StateFlow<Boolean>
}

