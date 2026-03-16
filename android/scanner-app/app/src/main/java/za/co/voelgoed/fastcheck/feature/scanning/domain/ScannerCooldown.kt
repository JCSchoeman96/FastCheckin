package za.co.voelgoed.fastcheck.feature.scanning.domain

import kotlin.math.max

data class ScannerCooldown(
    val startedAtEpochMillis: Long,
    val endsAtEpochMillis: Long
) {
    val durationMillis: Long
        get() = endsAtEpochMillis - startedAtEpochMillis

    fun remainingMillis(nowEpochMillis: Long): Long =
        max(0L, endsAtEpochMillis - nowEpochMillis)

    companion object {
        fun create(startedAtEpochMillis: Long, durationMillis: Long): ScannerCooldown =
            ScannerCooldown(
                startedAtEpochMillis = startedAtEpochMillis,
                endsAtEpochMillis = startedAtEpochMillis + durationMillis
            )
    }
}
