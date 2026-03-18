package za.co.voelgoed.fastcheck.core.autoflush

import kotlin.math.min

/**
 * Computes retry delays for transient flush failures.
 *
 * The coordinator owns retry episode semantics; this type is only responsible
 * for producing a bounded delay with jitter.
 */
fun interface RetryBackoff {
    fun delayMs(attempt: Int): Long
}

class FullJitterExponentialBackoff(
    private val baseDelayMs: Long = 1_000,
    private val capDelayMs: Long = 60_000,
    private val nextRandomLong: (boundExclusive: Long) -> Long
) : RetryBackoff {
    override fun delayMs(attempt: Int): Long {
        require(attempt >= 1) { "attempt must be >= 1" }
        val exp = baseDelayMs * (1L shl (attempt - 1).coerceAtMost(30))
        val capped = min(exp, capDelayMs)
        if (capped <= 1L) return 0L
        return nextRandomLong(capped + 1)
    }
}

