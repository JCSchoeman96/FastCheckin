package za.co.voelgoed.fastcheck.domain.policy

import java.time.Duration

object AdmissionRuntimePolicy {
    val ATTENDEE_CACHE_STALE_THRESHOLD: Duration = Duration.ofMinutes(30)
    val ADMISSION_TIME_SKEW_TOLERANCE: Duration = Duration.ofMinutes(2)
    val LOCAL_REPLAY_SUPPRESSION_WINDOW: Duration = Duration.ofSeconds(3)
}
