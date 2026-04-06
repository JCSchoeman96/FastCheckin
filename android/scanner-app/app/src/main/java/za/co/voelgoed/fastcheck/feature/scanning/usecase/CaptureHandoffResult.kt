package za.co.voelgoed.fastcheck.feature.scanning.usecase

/**
 * Represents the outcome of handing a decoded capture off to the local queue boundary.
 *
 * This models only the local handoff result, not remote upload or backend acceptance.
 */
sealed class CaptureHandoffResult {
    /**
     * The capture was accepted by the local admission boundary.
     */
    data class Accepted(
        val attendeeId: Long,
        val displayName: String,
        val ticketCode: String,
        val idempotencyKey: String,
        val scannedAt: String
    ) : CaptureHandoffResult()

    /**
     * The capture was rejected by local gate rules.
     */
    data class Rejected(
        val reason: String,
        val ticketCode: String,
        val displayName: String? = null
    ) : CaptureHandoffResult()

    /**
     * The capture requires manual review because local gate confidence is
     * degraded.
     */
    data class ReviewRequired(
        val reason: String,
        val ticketCode: String,
        val displayName: String? = null
    ) : CaptureHandoffResult()

    /**
     * The capture was intentionally ignored because a short global cooldown
     * window is still active.
     */
    data object SuppressedByCooldown : CaptureHandoffResult()

    /**
     * The capture could not be handed off due to an operational failure.
     */
    data class Failed(val reason: String) : CaptureHandoffResult()
}
