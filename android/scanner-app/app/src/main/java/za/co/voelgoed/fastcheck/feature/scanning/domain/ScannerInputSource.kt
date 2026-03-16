package za.co.voelgoed.fastcheck.feature.scanning.domain

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * A domain-level contract for any source that can emit scanner capture events.
 *
 * Implementations are responsible for managing the underlying platform or hardware
 * lifecycle and translating platform events into [ScannerSourceState] and
 * [ScannerCaptureEvent] streams.
 *
 * Implementations must not perform queueing, session management, ticket-code
 * normalization, or any network or persistence work. Those responsibilities belong in
 * downstream layers.
 */
interface ScannerInputSource {

    /**
     * The classification of this scanner source (for example, camera or keyboard wedge).
     */
    val type: ScannerSourceType

    /**
     * Optional opaque identifier for this particular source instance.
     *
     * The meaning of this value is left to the implementation (for example, camera ID,
     * HID device identifier, or broadcast channel name).
     */
    val id: String?

    /**
     * A stream of lifecycle state changes for this source.
     */
    val state: StateFlow<ScannerSourceState>

    /**
     * A stream of capture events produced by this source.
     */
    val captures: Flow<ScannerCaptureEvent>

    /**
     * Request that the source start running and begin emitting [ScannerSourceState] and
     * [ScannerCaptureEvent] updates.
     */
    fun start()

    /**
     * Request that the source stop running and cease emitting new events.
     */
    fun stop()
}

