package za.co.voelgoed.fastcheck.domain.policy

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

class CurrentEventAdmissionReadinessTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-06T10:00:00Z"), ZoneOffset.UTC)
    private val readiness = CurrentEventAdmissionReadiness(clock)

    @Test
    fun trustedCacheRequiresMatchingFreshSuccessfulSyncBoundary() {
        val trusted =
            readiness.evaluate(
                eventId = 42L,
                syncStatus =
                    AttendeeSyncStatus(
                        eventId = 42L,
                        lastServerTime = "2026-04-06T09:45:00Z",
                        lastSuccessfulSyncAt = "2026-04-06T09:45:00Z",
                        syncType = "full",
                        attendeeCount = 100
                    )
            )

        assertThat(trusted.isTrusted).isTrue()
        assertThat(trusted.reason).isEqualTo(AdmissionReadinessReason.Ready)
    }

    @Test
    fun staleCacheIsNotTrusted() {
        val stale =
            readiness.evaluate(
                eventId = 42L,
                syncStatus =
                    AttendeeSyncStatus(
                        eventId = 42L,
                        lastServerTime = "2026-04-06T09:00:00Z",
                        lastSuccessfulSyncAt = "2026-04-06T09:00:00Z",
                        syncType = "full",
                        attendeeCount = 100
                    )
            )

        assertThat(stale.isTrusted).isFalse()
        assertThat(stale.reason).isEqualTo(AdmissionReadinessReason.Stale)
    }
}
