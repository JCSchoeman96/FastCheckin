package za.co.voelgoed.fastcheck.feature.scanning.usecase

/**
 * Represents the outcome of handing a decoded capture off to the local queue boundary.
 *
 * This models only the local handoff result, not remote upload or backend acceptance.
 */
sealed class CaptureHandoffResult {
    /**
     * The capture was accepted by the local queue boundary.
     */
    data object Accepted : CaptureHandoffResult()

    /**
     * The capture could not be handed off due to an operational failure.
     */
    data class Failed(val reason: String) : CaptureHandoffResult()
}

