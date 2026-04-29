package za.co.voelgoed.fastcheck.core.sync

import java.util.concurrent.TimeUnit

/**
 * Centralized tunable defaults for [DefaultAttendeeSyncOrchestrator].
 */
data class AttendeeSyncOrchestratorConfig(
    val periodicBaseMs: Long = TimeUnit.MINUTES.toMillis(5),
    val periodicJitterMaxMs: Long = TimeUnit.SECONDS.toMillis(60),
    val scanActivePeriodicBaseMs: Long = TimeUnit.SECONDS.toMillis(90),
    val scanActivePeriodicJitterMaxMs: Long = TimeUnit.SECONDS.toMillis(30),
    val fullReconcileWallClockMs: Long = TimeUnit.HOURS.toMillis(24),
    val fullReconcileEveryIncrementalCycles: Int = 20,
    val backoffScheduleMs: LongArray = longArrayOf(
        TimeUnit.SECONDS.toMillis(30),
        TimeUnit.MINUTES.toMillis(1),
        TimeUnit.MINUTES.toMillis(2),
        TimeUnit.MINUTES.toMillis(5)
    )
)
