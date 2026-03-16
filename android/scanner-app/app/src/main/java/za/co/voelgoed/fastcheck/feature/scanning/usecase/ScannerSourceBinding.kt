package za.co.voelgoed.fastcheck.feature.scanning.usecase

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState

/**
 * Coordinates a [ScannerInputSource] and forwards captured values into an existing
 * [DecodedBarcodeHandler] pipeline.
 *
 * This class owns a child coroutine scope for collecting capture events. It exposes the
 * source's lifecycle state for observers, but it does not perform any queueing,
 * network, or persistence work itself.
 */
class ScannerSourceBinding(
    private val source: ScannerInputSource,
    private val decodedBarcodeHandler: DecodedBarcodeHandler,
    private val parentScope: CoroutineScope
) {

    private var bindingJob: Job? = null

    /**
     * Exposes the underlying source's lifecycle state directly.
     */
    val sourceState: StateFlow<ScannerSourceState>
        get() = source.state

    /**
     * Start coordinating the source and forwarding captured values.
     *
     * This method is idempotent: if the binding is already active, subsequent calls are
     * ignored.
     */
    fun start() {
        if (bindingJob?.isActive == true) return

        val parentJob = parentScope.coroutineContext[Job]
        val childJob = SupervisorJob(parentJob)
        val childScope = CoroutineScope(parentScope.coroutineContext + childJob)

        try {
            childScope.launch(start = CoroutineStart.UNDISPATCHED) {
                source.captures.collect { event ->
                    decodedBarcodeHandler.onDecoded(event.rawValue)
                }
            }

            bindingJob = childJob

            source.start()
        } catch (t: Throwable) {
            // Ensure we do not leave a half-alive binding behind if the source fails to start.
            childJob.cancel()
            bindingJob = null
            throw t
        }
    }

    /**
     * Stop coordinating the source and stop forwarding captured values.
     *
     * This method is idempotent: if the binding is not active, the call is ignored.
     */
    fun stop() {
        val job = bindingJob
        if (job == null || !job.isActive) {
            return
        }

        job.cancel()
        bindingJob = null
        source.stop()
    }
}

