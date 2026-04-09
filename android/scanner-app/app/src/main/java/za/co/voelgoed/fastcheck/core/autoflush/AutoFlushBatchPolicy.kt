package za.co.voelgoed.fastcheck.core.autoflush

object AutoFlushBatchPolicy {
    const val MIN_BATCH_SIZE: Int = 10
    const val DEFAULT_BATCH_SIZE: Int = 25
    const val MAX_BATCH_SIZE: Int = 50

    fun clamp(batchSize: Int): Int = batchSize.coerceIn(MIN_BATCH_SIZE, MAX_BATCH_SIZE)
}
