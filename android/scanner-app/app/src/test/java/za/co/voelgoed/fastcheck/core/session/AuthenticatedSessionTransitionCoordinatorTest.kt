package za.co.voelgoed.fastcheck.core.session

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadata
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.data.repository.EventBucketRepository
import za.co.voelgoed.fastcheck.domain.model.EventBucket
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class AuthenticatedSessionTransitionCoordinatorTest {
    private val clock = Clock.fixed(Instant.parse("2026-08-03T10:00:00Z"), ZoneOffset.UTC)

    @Test fun dataStoreOnlyStateRestoresLoggedOut() = runTest {
        val metadata = FakeMetadataStore().apply { value = session().toMetadata() }
        val coordinator = coordinator(FakeContextStore(), metadata, FakeBucketRepository())
        assertThat(coordinator.restore()).isNull()
        assertThat(metadata.value).isNull()
    }

    @Test fun secureOnlyStateRepairsDisplayCacheAndRemainsAuthenticated() = runTest {
        val secure = FakeContextStore(context())
        val metadata = FakeMetadataStore()
        val buckets = FakeBucketRepository().apply { rows[7] = bucket(7, "Event Seven") }
        val restored = coordinator(secure, metadata, buckets).restore()
        assertThat(restored?.eventId).isEqualTo(7)
        assertThat(restored?.eventName).isEqualTo("Event Seven")
        assertThat(metadata.value?.sessionGeneration).isEqualTo(4)
        assertThat(buckets.rows[7]?.state).isEqualTo("ACTIVE")
    }

    @Test fun staleDisplayCacheIsRepairedFromSecureIdentityAndBucketMetadata() = runTest {
        val secure = FakeContextStore(context(eventId = 7, generation = 4))
        val metadata = FakeMetadataStore().apply {
            value = session().copy(eventId = 3, eventName = "Wrong Event", sessionGeneration = 2).toMetadata()
        }
        val buckets = FakeBucketRepository().apply { rows[7] = bucket(7, "Event Seven") }

        val restored = coordinator(secure, metadata, buckets).restore()

        assertThat(restored?.eventName).isEqualTo("Event Seven")
        assertThat(metadata.value?.eventId).isEqualTo(7L)
        assertThat(metadata.value?.sessionGeneration).isEqualTo(4L)
    }

    @Test fun displayCacheWriteFailureDoesNotInvalidateCommittedSecureLogin() = runTest {
        val secure = FakeContextStore()
        val metadata = FakeMetadataStore(failSave = true)
        val committed = coordinator(secure, metadata, FakeBucketRepository()).commitLogin(session(), "jwt")
        assertThat(committed.sessionGeneration).isEqualTo(1)
        assertThat(secure.capture()?.bearerToken).isEqualTo("jwt")
    }

    @Test fun bucketActivationFailurePreservesPreviousSecureContext() = runTest {
        val previous = context(eventId = 3, generation = 8)
        val secure = FakeContextStore(previous)
        val buckets = FakeBucketRepository(failActivationFor = 7)
        assertThat(runCatching { coordinator(secure, FakeMetadataStore(), buckets).commitLogin(session(), "new") }.isFailure).isTrue()
        assertThat(secure.capture()).isEqualTo(previous)
    }

    @Test fun secureReplacementFailureReactivatesPreviousBucket() = runTest {
        val secure = FakeContextStore(context(eventId = 3, generation = 8), failReplace = true)
        val buckets = FakeBucketRepository().apply { rows[3] = bucket(3, "Previous") }
        assertThat(runCatching { coordinator(secure, FakeMetadataStore(), buckets).commitLogin(session(), "new") }.isFailure).isTrue()
        assertThat(buckets.rows[3]?.state).isEqualTo("ACTIVE")
        assertThat(secure.capture()?.eventId).isEqualTo(3)
    }

    @Test fun staleExpiryCannotClearNewerSameEventGeneration() = runTest {
        val secure = FakeContextStore(context(eventId = 7, generation = 14))
        val buckets = FakeBucketRepository().apply { rows[7] = bucket(7, "Seven", "ACTIVE") }
        coordinator(secure, FakeMetadataStore(), buckets).expire(AuthenticatedEventIdentity(7, 12))
        assertThat(secure.currentIdentity()?.sessionGeneration).isEqualTo(14)
        assertThat(buckets.rows[7]?.state).isEqualTo("ACTIVE")
    }

    @Test fun unresolvedParkedEventDoesNotBlockDifferentEventLogin() = runTest {
        val secure = FakeContextStore(context(eventId = 3, generation = 8))
        val buckets = FakeBucketRepository().apply {
            rows[3] = bucket(3, "Event A", "ACTIVE").copy(pendingUploadCount = 14)
        }
        val coordinator = coordinator(secure, FakeMetadataStore(), buckets)

        coordinator.logout()
        val committed = coordinator.commitLogin(session(), "event-b-jwt")

        assertThat(committed.eventId).isEqualTo(7L)
        assertThat(buckets.rows[3]?.pendingUploadCount).isEqualTo(14)
        assertThat(buckets.rows[3]?.state).isEqualTo("PARKED")
        assertThat(buckets.rows[7]?.state).isEqualTo("ACTIVE")
    }

    @Test fun unresolvedOtherBucketDoesNotBlockRestoringAuthoritativeSession() = runTest {
        val secure = FakeContextStore(context(eventId = 7, generation = 9))
        val buckets = FakeBucketRepository().apply {
            rows[3] = bucket(3, "Event A").copy(conflictCount = 2)
            rows[7] = bucket(7, "Event B")
        }

        val restored = coordinator(secure, FakeMetadataStore(), buckets).restore()

        assertThat(restored?.eventId).isEqualTo(7L)
        assertThat(buckets.rows[3]?.conflictCount).isEqualTo(2)
        assertThat(buckets.rows[7]?.state).isEqualTo("ACTIVE")
    }

    @Test fun staleOtherEvent401MarksOnlyItsBucketAndKeepsCurrentSession() = runTest {
        val secure = FakeContextStore(context(eventId = 7, generation = 14))
        val buckets = FakeBucketRepository().apply {
            rows[3] = bucket(3, "Event A")
            rows[7] = bucket(7, "Event B", "ACTIVE")
        }

        coordinator(secure, FakeMetadataStore(), buckets)
            .expire(AuthenticatedEventIdentity(eventId = 3, sessionGeneration = 12))

        assertThat(secure.currentIdentity()).isEqualTo(AuthenticatedEventIdentity(7, 14))
        assertThat(buckets.rows[3]?.state).isEqualTo("AUTH_REQUIRED")
        assertThat(buckets.rows[7]?.state).isEqualTo("ACTIVE")
    }

    private fun coordinator(secure: FakeContextStore, metadata: FakeMetadataStore, buckets: FakeBucketRepository) =
        AuthenticatedSessionTransitionCoordinator(secure, metadata, buckets, clock)

    private fun session() = ScannerSession(7, "Event Seven", "E7", 3600, clock.millis(), clock.millis() + 3_600_000)
    private fun context(eventId: Long = 7, generation: Long = 4) =
        AuthenticatedEventContext(eventId, "jwt", generation, clock.millis(), clock.millis() + 3_600_000)
    private fun bucket(eventId: Long, name: String, state: String = "PARKED") =
        EventBucket(eventId, name, null, state, 0, 0, 0, 0, clock.millis())
    private fun ScannerSession.toMetadata() = SessionMetadata(
        eventId, eventName, eventShortname, expiresInSeconds, authenticatedAtEpochMillis,
        expiresAtEpochMillis, sessionGeneration = sessionGeneration
    )

    private class FakeMetadataStore(private val failSave: Boolean = false) : SessionMetadataStore {
        var value: SessionMetadata? = null
        override suspend fun load() = value
        override suspend fun save(metadata: SessionMetadata) { if (failSave) error("save"); value = metadata }
        override suspend fun clear() { value = null }
    }

    private class FakeContextStore(
        private var value: AuthenticatedEventContext? = null,
        private val failReplace: Boolean = false
    ) : AuthenticatedEventContextStore {
        private val identities = MutableStateFlow(value?.identity)
        override suspend fun capture() = value
        override suspend fun currentIdentity() = value?.identity
        override suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long): AuthenticatedEventContext {
            if (failReplace) error("replace")
            val next = AuthenticatedEventContext(eventId, bearerToken, (value?.sessionGeneration ?: 0) + 1, authenticatedAtEpochMillis, expiresAtEpochMillis)
            value = next; identities.value = next.identity; return next
        }
        override suspend fun clearIfGenerationMatches(sessionGeneration: Long): Boolean {
            if (value?.sessionGeneration != sessionGeneration) return false
            value = null; identities.value = null; return true
        }
        override suspend fun isCurrent(sessionGeneration: Long) = value?.sessionGeneration == sessionGeneration
        override fun observeIdentity(): Flow<AuthenticatedEventIdentity?> = identities
    }

    private class FakeBucketRepository(private val failActivationFor: Long? = null) : EventBucketRepository {
        val rows = linkedMapOf<Long, EventBucket>()
        override suspend fun activate(eventId: Long, eventName: String, eventShortname: String?) {
            if (eventId == failActivationFor) error("activate")
            rows.replaceAll { _, row -> if (row.state == "ACTIVE") row.copy(state = "PARKED") else row }
            rows[eventId] = (rows[eventId] ?: EventBucket(eventId, eventName, eventShortname, "PARKED", 0, 0, 0, 0, 0)).copy(eventName = eventName, eventShortname = eventShortname, state = "ACTIVE")
        }
        override suspend fun park(eventId: Long) { rows[eventId]?.let { rows[eventId] = it.copy(state = "PARKED") } }
        override suspend fun markAuthRequired(eventId: Long) { rows[eventId]?.let { rows[eventId] = it.copy(state = "AUTH_REQUIRED") } }
        override suspend fun refreshSnapshots(eventId: Long) = Unit
        override suspend fun load(eventId: Long) = rows[eventId]
        override fun observeAllBuckets(): Flow<List<EventBucket>> = MutableStateFlow(rows.values.toList())
    }
}
