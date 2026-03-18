package za.co.voelgoed.fastcheck.core.autoflush

/**
 * Abstraction over runtime connectivity checks used by [AutoFlushCoordinator]
 * to decide whether auto-flush should be attempted.
 */
fun interface ConnectivityProvider {
    suspend fun isOnline(): Boolean
}

