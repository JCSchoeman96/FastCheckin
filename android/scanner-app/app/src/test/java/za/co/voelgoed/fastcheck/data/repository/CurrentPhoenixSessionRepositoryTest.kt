package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import retrofit2.Response
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadata
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.security.SessionVault
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.remote.MobileLoginPayload
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest

@RunWith(RobolectricTestRunner::class)
class CurrentPhoenixSessionRepositoryTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:00:00Z"), ZoneOffset.UTC)
    private val openedDatabases = mutableListOf<FastCheckDatabase>()

    @After
    fun tearDown() {
        openedDatabases.forEach(FastCheckDatabase::close)
        openedDatabases.clear()
    }

    @Test
    fun persistsJwtSeparatelyFromSessionMetadata() = runTest {
        val vault = FakeSessionVault()
        val metadataStore = FakeSessionMetadataStore()
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(
                                data =
                                    MobileLoginPayload(
                                        token = "jwt-token",
                                        event_id = 77,
                                        event_name = "FastCheck Event",
                                        expires_in = 7200
                                    ),
                                error = null,
                                message = null
                            )
                        )
                    ),
                sessionVault = vault,
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = unresolvedGate(),
                localRuntimeDataCleaner = FakeLocalRuntimeDataCleaner(),
                clock = clock
            )

        val session = repository.login(eventId = 77, credential = "scanner-secret")

        assertThat(vault.token).isEqualTo("jwt-token")
        assertThat(metadataStore.saved?.eventId).isEqualTo(77)
        assertThat(metadataStore.saved?.eventName).isEqualTo("FastCheck Event")
        assertThat(session.expiresAtEpochMillis).isEqualTo(1_773_396_000_000)
    }

    /**
     * Auth-expired re-login calls [SessionRepository.logout] to return to the login gate.
     * That path must not wipe local durable queue rows or admission overlays — only JWT + session metadata.
     * (See MainActivity.handleReloginForAuthExpired: dismissLogoutConfirmation + sessionGateViewModel.logout.)
     */
    @Test
    fun logoutClearsSessionAndRunsExplicitLogoutCleaner_preservesDurableRuntimeRows() = runTest {
        val vault = FakeSessionVault()
        runBlocking {
            vault.storeToken("jwt")
        }
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Test Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = clock.millis(),
                        expiresAtEpochMillis = clock.millis() + 3_600_000L
                    )
            }

        val context = ApplicationProvider.getApplicationContext<Context>()
        val database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        openedDatabases += database
        val dao = database.scannerDao()
        runBlocking {
            dao.insertQueuedScan(
                QueuedScanEntity(
                    eventId = 5,
                    ticketCode = "VG-1",
                    idempotencyKey = "idem-queue-relogin-contract",
                    createdAt = clock.millis(),
                    scannedAt = "2026-03-13T08:00:00Z",
                    entranceName = "Main",
                    operatorName = "Op"
                )
            )
            dao.upsertLocalAdmissionOverlay(
                LocalAdmissionOverlayEntity(
                    eventId = 5,
                    attendeeId = 99L,
                    ticketCode = "VG-1",
                    idempotencyKey = "idem-overlay-relogin-contract",
                    state = "PENDING_LOCAL",
                    createdAtEpochMillis = clock.millis(),
                    overlayScannedAt = "2026-03-13T08:00:00Z",
                    expectedRemainingAfterOverlay = 0,
                    operatorName = "Op",
                    entranceName = "Main"
                )
            )
            dao.insertQuarantinedScans(
                listOf(
                    QuarantinedScanEntity(
                        originalQueueId = null,
                        createdAt = clock.millis(),
                        scannedAt = "2026-03-13T08:00:00Z",
                        direction = "in",
                        entranceName = "Main",
                        operatorName = "Op",
                        lastAttemptAt = null,
                        quarantineReason = "duplicate_capture",
                        quarantineMessage = "duplicate_capture",
                        batchAttributed = false,
                        overlayStateAtQuarantine = "PENDING_LOCAL",
                        idempotencyKey = "idem-quarantine-relogin-contract",
                        eventId = 5,
                        ticketCode = "VG-1",
                        quarantinedAt = "2026-03-13T08:00:00Z",
                    )
                )
            )
        }
        val cleaner = FakeLocalRuntimeDataCleaner()

        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "unused", message = "unused")
                        )
                    ),
                sessionVault = vault,
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = UnresolvedAdmissionStateGate.fromLoader { emptyList() },
                localRuntimeDataCleaner = cleaner,
                clock = clock
            )

        repository.logout()

        assertThat(vault.token).isNull()
        assertThat(metadataStore.saved).isNull()
        runBlocking {
            assertThat(dao.loadQueuedScans()).hasSize(1)
            assertThat(dao.loadOverlaysByState("PENDING_LOCAL")).hasSize(1)
            assertThat(dao.countQuarantinedScans()).isEqualTo(1)
        }
        assertThat(cleaner.explicitLogoutCalls).isEqualTo(1)
    }

    @Test
    fun onAuthExpiredClearsSessionAndRunsAuthExpiredCleaner() = runTest {
        val vault = FakeSessionVault().apply { runBlocking { storeToken("jwt") } }
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Test Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = clock.millis(),
                        expiresAtEpochMillis = clock.millis() + 3_600_000L
                    )
            }
        val cleaner = FakeLocalRuntimeDataCleaner()
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "unused", message = "unused")
                        )
                    ),
                sessionVault = vault,
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = unresolvedGate(),
                localRuntimeDataCleaner = cleaner,
                clock = clock
            )

        repository.onAuthExpired()

        assertThat(vault.token).isNull()
        assertThat(metadataStore.saved).isNull()
        assertThat(cleaner.authExpiredCalls).isEqualTo(1)
    }

    @Test
    fun restoresCurrentSessionFromStoredMetadata() = runTest {
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Stored Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = 1_773_388_800_000,
                        expiresAtEpochMillis = 1_773_392_400_000
                    )
            }

        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "unused", message = "unused")
                        )
                    ),
                sessionVault = FakeSessionVault(),
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = unresolvedGate(),
                localRuntimeDataCleaner = FakeLocalRuntimeDataCleaner(),
                clock = clock
            )

        val session = repository.currentSession()

        assertThat(session?.eventId).isEqualTo(5)
        assertThat(session?.eventName).isEqualTo("Stored Event")
        assertThat(session?.authenticatedAtEpochMillis).isEqualTo(1_773_388_800_000)
    }

    @Test
    fun loginBlocksWhenAnotherEventHasUnresolvedOverlayState() = runTest {
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "unused", message = "unused")
                        )
                    ),
                sessionVault = FakeSessionVault(),
                sessionMetadataStore = FakeSessionMetadataStore(),
                unresolvedAdmissionStateGate = unresolvedGateWithOverlay(eventId = 55L),
                localRuntimeDataCleaner = FakeLocalRuntimeDataCleaner(),
                clock = clock
            )

        val failure =
            runCatching { repository.login(eventId = 77, credential = "scanner-secret") }
                .exceptionOrNull()

        assertThat(failure).isInstanceOf(CrossEventUnresolvedStateException::class.java)
        assertThat(failure?.message).contains("event 55")
    }

    @Test
    fun loginToDifferentEventRunsCleanEventTransitionBeforePersistingNewSession() = runTest {
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Old Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = clock.millis(),
                        expiresAtEpochMillis = clock.millis() + 3_600_000L
                    )
            }
        val cleaner = FakeLocalRuntimeDataCleaner()
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(
                                data =
                                    MobileLoginPayload(
                                        token = "jwt-new",
                                        event_id = 7,
                                        event_name = "New Event",
                                        expires_in = 3600
                                    ),
                                error = null,
                                message = null
                            )
                        )
                    ),
                sessionVault = FakeSessionVault(),
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = unresolvedGate(),
                localRuntimeDataCleaner = cleaner,
                clock = clock
            )

        val session = repository.login(eventId = 7, credential = "credential")

        assertThat(cleaner.cleanTransitionCalls).isEqualTo(1)
        assertThat(session.eventId).isEqualTo(7)
    }

    @Test
    fun failedLoginToDifferentEventDoesNotRunCleanEventTransition() = runTest {
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Old Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = clock.millis(),
                        expiresAtEpochMillis = clock.millis() + 3_600_000L
                    )
            }
        val cleaner = FakeLocalRuntimeDataCleaner()
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "bad credential", message = "Login failed")
                        )
                    ),
                sessionVault = FakeSessionVault(),
                sessionMetadataStore = metadataStore,
                unresolvedAdmissionStateGate = unresolvedGate(),
                localRuntimeDataCleaner = cleaner,
                clock = clock
            )

        val failure =
            runCatching { repository.login(eventId = 7, credential = "wrong") }
                .exceptionOrNull()

        assertThat(failure).isNotNull()
        assertThat(cleaner.cleanTransitionCalls).isEqualTo(0)
        assertThat(metadataStore.saved?.eventId).isEqualTo(5)
    }

    private class FakeSessionVault : SessionVault {
        var token: String? = null

        override suspend fun storeToken(token: String) {
            this.token = token
        }

        override suspend fun loadToken(): String? = token

        override suspend fun clearToken() {
            token = null
        }
    }

    private class FakeSessionMetadataStore : SessionMetadataStore {
        var saved: SessionMetadata? = null

        override suspend fun load(): SessionMetadata? = saved

        override suspend fun save(metadata: SessionMetadata) {
            saved = metadata
        }

        override suspend fun clear() {
            saved = null
        }
    }

    private class FakeLocalRuntimeDataCleaner : LocalRuntimeDataCleaner {
        var explicitLogoutCalls: Int = 0
        var authExpiredCalls: Int = 0
        var cleanTransitionCalls: Int = 0

        override suspend fun handleExplicitLogout(currentEventId: Long?) {
            explicitLogoutCalls += 1
        }

        override suspend fun handleAuthExpired(currentEventId: Long?) {
            authExpiredCalls += 1
        }

        override suspend fun handleCleanEventTransition(fromEventId: Long?, toEventId: Long) {
            cleanTransitionCalls += 1
        }
    }

    private class FakePhoenixMobileApi(
        private val loginResponse: MobileLoginResponse
    ) : PhoenixMobileApi {
        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse = loginResponse

        override suspend fun syncAttendees(
            since: String?,
            cursor: String?,
            sinceInvalidationId: Long,
            limit: Int
        ): MobileSyncResponse {
            error("Not used in this test")
        }

        override suspend fun uploadScans(body: UploadScansRequest): Response<UploadScansResponse> {
            error("Not used in this test")
        }
    }

    private fun unresolvedGate(): UnresolvedAdmissionStateGate = buildGate()

    private fun unresolvedGateWithOverlay(eventId: Long): UnresolvedAdmissionStateGate =
        buildGate { database ->
            database.scannerDao().upsertLocalAdmissionOverlay(
                LocalAdmissionOverlayEntity(
                    eventId = eventId,
                    attendeeId = 12L,
                    ticketCode = "VG-012",
                    idempotencyKey = "idem-$eventId",
                    state = "PENDING_LOCAL",
                    createdAtEpochMillis = clock.millis(),
                    overlayScannedAt = "2026-03-13T08:00:00Z",
                    expectedRemainingAfterOverlay = 0,
                    operatorName = "Op",
                    entranceName = "Main"
                )
            )
        }

    private fun buildGate(
        seed: (suspend (FastCheckDatabase) -> Unit)? = null
    ): UnresolvedAdmissionStateGate {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        openedDatabases += database
        runBlockingTestSeed(database, seed)
        return UnresolvedAdmissionStateGate(database.scannerDao())
    }

    private fun runBlockingTestSeed(
        database: FastCheckDatabase,
        seed: (suspend (FastCheckDatabase) -> Unit)?
    ) {
        if (seed == null) return
        runBlocking {
            seed(database)
        }
    }
}
