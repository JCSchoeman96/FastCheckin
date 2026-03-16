package za.co.voelgoed.fastcheck.feature.scanning.domain

/**
 * Represents the runtime lifecycle of a scanner input source.
 *
 * This models whether a source is idle, in the process of starting, ready to emit
 * captures, shutting down, or has encountered a runtime error. It does not model any
 * backend, queue, or upload outcome.
 */
sealed class ScannerSourceState {

    /**
     * The source is not currently running and is not expected to emit captures.
     */
    data object Idle : ScannerSourceState()

    /**
     * The source is in the process of starting up and may not yet be ready to emit captures.
     */
    data object Starting : ScannerSourceState()

    /**
     * The source is running and ready to emit capture events.
     */
    data object Ready : ScannerSourceState()

    /**
     * The source is shutting down and will soon transition back to [Idle].
     */
    data object Stopping : ScannerSourceState()

    /**
     * The source encountered a runtime error.
     *
     * [reason] is intended for diagnostics and logging, not as a user-facing message.
     */
    data class Error(val reason: String) : ScannerSourceState()
}

