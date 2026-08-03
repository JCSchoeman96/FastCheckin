package za.co.voelgoed.fastcheck.core.session

import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.data.repository.EventBucketRepository
import za.co.voelgoed.fastcheck.data.local.EventLocalBucketState
import za.co.voelgoed.fastcheck.data.mapper.toMetadata
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@Singleton
class AuthenticatedSessionTransitionCoordinator @Inject constructor(
    private val contextStore: AuthenticatedEventContextStore,
    private val metadataStore: SessionMetadataStore,
    private val bucketRepository: EventBucketRepository,
    private val clock: Clock
) {
    private val mutex = Mutex()

    suspend fun commitLogin(session: ScannerSession, bearerToken: String): ScannerSession = mutex.withLock {
        val previous = contextStore.capture()
        val previousBucket = previous?.let { bucketRepository.load(it.eventId) }
        try {
            bucketRepository.activate(session.eventId, session.eventName, session.eventShortname)
        } catch (failure: Throwable) {
            throw failure
        }
        val context = try {
            contextStore.replace(session.eventId, bearerToken, session.authenticatedAtEpochMillis, session.expiresAtEpochMillis)
        } catch (failure: Throwable) {
            if (previousBucket != null) {
                bucketRepository.activate(previousBucket.eventId, previousBucket.eventName ?: "Event #${previousBucket.eventId}", previousBucket.eventShortname)
            } else {
                bucketRepository.park(session.eventId)
            }
            throw failure
        }
        val committed = session.copy(sessionGeneration = context.sessionGeneration)
        runCatching { metadataStore.save(committed.toMetadata()) }
        committed
    }

    suspend fun restore(): ScannerSession? = mutex.withLock {
        val context = contextStore.capture()
        if (context == null) {
            runCatching { metadataStore.clear() }
            return@withLock null
        }
        if (context.expiresAtEpochMillis <= clock.millis()) {
            bucketRepository.markAuthRequired(context.eventId)
            contextStore.clearIfGenerationMatches(context.sessionGeneration)
            runCatching { metadataStore.clear() }
            return@withLock null
        }
        val cached = runCatching { metadataStore.load() }.getOrNull()?.takeIf {
            it.eventId == context.eventId && it.sessionGeneration == context.sessionGeneration
        }
        val bucket = bucketRepository.load(context.eventId)
        val session = ScannerSession(
            eventId = context.eventId,
            eventName = cached?.eventName ?: bucket?.eventName ?: "Event #${context.eventId}",
            eventShortname = cached?.eventShortname ?: bucket?.eventShortname,
            expiresInSeconds = ((context.expiresAtEpochMillis - context.authenticatedAtEpochMillis) / 1000).toInt(),
            authenticatedAtEpochMillis = context.authenticatedAtEpochMillis,
            expiresAtEpochMillis = context.expiresAtEpochMillis,
            sessionGeneration = context.sessionGeneration
        )
        if (bucket?.state != EventLocalBucketState.ACTIVE) {
            bucketRepository.activate(session.eventId, session.eventName, session.eventShortname)
        }
        if (cached?.sessionGeneration != context.sessionGeneration) runCatching { metadataStore.save(session.toMetadata()) }
        session
    }

    suspend fun logout() = mutex.withLock {
        val context = contextStore.capture() ?: run { metadataStore.clear(); return@withLock }
        bucketRepository.park(context.eventId)
        contextStore.clearIfGenerationMatches(context.sessionGeneration)
        runCatching { metadataStore.clear() }
    }

    suspend fun expire(identity: AuthenticatedEventIdentity) = mutex.withLock {
        val current = contextStore.currentIdentity()
        if (current?.eventId == identity.eventId && current.sessionGeneration > identity.sessionGeneration) return@withLock
        bucketRepository.markAuthRequired(identity.eventId)
        if (contextStore.clearIfGenerationMatches(identity.sessionGeneration)) runCatching { metadataStore.clear() }
    }

    suspend fun expireCurrent() {
        contextStore.currentIdentity()?.let { expire(it) }
    }
}
