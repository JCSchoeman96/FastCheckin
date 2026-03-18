package za.co.voelgoed.fastcheck.core.autoflush

import kotlinx.coroutines.flow.StateFlow
import za.co.voelgoed.fastcheck.domain.model.FlushReport

/**
 * Single-process coordinator for all scan-queue flush orchestration.
 *
 * This interface models only orchestration concerns (when and how many times
 * to invoke the underlying flush use case). It does not own queue admission,
 * persistence, or backend contracts.
 */
interface AutoFlushCoordinator {
    val state: StateFlow<AutoFlushCoordinatorState>

    fun requestFlush(trigger: AutoFlushTrigger)
}

data class AutoFlushCoordinatorState(
    val isFlushing: Boolean = false,
    val lastFlushReport: FlushReport? = null
)

sealed interface AutoFlushTrigger {
    data object Manual : AutoFlushTrigger
    data object AfterEnqueue : AutoFlushTrigger
    data object ConnectivityRestored : AutoFlushTrigger
    data object ForegroundResume : AutoFlushTrigger
    data object PostLogin : AutoFlushTrigger
    data object PostSync : AutoFlushTrigger
}

