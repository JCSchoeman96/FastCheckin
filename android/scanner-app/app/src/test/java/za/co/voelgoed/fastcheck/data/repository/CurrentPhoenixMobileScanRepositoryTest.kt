package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.test.runTest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import retrofit2.HttpException
import retrofit2.Response
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansPayload
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

@RunWith(RobolectricTestRunner::class)
class CurrentPhoenixMobileScanRepositoryTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var repository: CurrentPhoenixMobileScanRepository
    private lateinit var api: FakePhoenixMobileApi
    private val clock = Clock.fixed(Instant.parse("2026-03-12T10:00:00Z"), ZoneOffset.UTC)

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        api = FakePhoenixMobileApi()
        repository =
            CurrentPhoenixMobileScanRepository(
                scannerDao = database.scannerDao(),
                remoteDataSource = PhoenixMobileRemoteDataSource(api),
                sessionProvider = object : SessionProvider {
                    override suspend fun bearerToken(): String = "jwt-token"
                },
                flushResultClassifier = FlushResultClassifier(),
                clock = clock
            )
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun suppressesRepeatedRawTicketCodeInsideReplayWindow() = runTest {
        val first = repository.queueScan(sampleScan(idempotencyKey = "idem-1", createdAt = 1_000L))
        val second = repository.queueScan(sampleScan(idempotencyKey = "idem-2", createdAt = 3_500L))

        assertThat(first).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(second).isEqualTo(QueueCreationResult.ReplaySuppressed)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(1)
    }

    @Test
    fun treatsReplaySuppressionRowsAsExpiredOutsideWindowAndReplacesThemInline() = runTest {
        val first = repository.queueScan(sampleScan(idempotencyKey = "idem-1", createdAt = 1_000L))
        val second = repository.queueScan(sampleScan(idempotencyKey = "idem-2", createdAt = 4_000L))
        val suppressionRow = database.scannerDao().findReplaySuppression("VG-001")

        assertThat(first).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(second).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(suppressionRow?.seenAtEpochMillis).isEqualTo(4_000L)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(2)
    }

    @Test
    fun keepsUnmatchedQueueItemsForRetryAfterPartialSuccess() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-1", ticketCode = "VG-1", createdAt = 1_000L))
        repository.queueScan(sampleScan(idempotencyKey = "idem-2", ticketCode = "VG-2", createdAt = 5_000L))
        repository.queueScan(sampleScan(idempotencyKey = "idem-3", ticketCode = "VG-3", createdAt = 9_000L))

        api.uploadResponse =
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-2",
                                    status = "success",
                                    message = "Check-in successful"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val remainingQueued = database.scannerDao().loadQueuedScans()
        val persistedReport = repository.latestFlushReport()

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(report.itemOutcomes.map { it.outcome })
            .containsExactly(
                FlushItemOutcome.RETRYABLE_FAILURE,
                FlushItemOutcome.SUCCESS,
                FlushItemOutcome.RETRYABLE_FAILURE
            )
            .inOrder()
        assertThat(report.retryableRemainingCount).isEqualTo(2)
        assertThat(remainingQueued.map { it.idempotencyKey }).containsExactly("idem-1", "idem-3").inOrder()
        assertThat(persistedReport?.summaryMessage).isEqualTo("Flush completed with retry backlog.")
    }

    @Test
    fun persistsSecondaryReasonDetailAndRemovesTerminalItemsAsBefore() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-1", ticketCode = "VG-1", createdAt = 1_000L))

        api.uploadResponse =
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-1",
                                    status = "error",
                                    message = "Already processed",
                                    reason_code = "business_duplicate"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val replayCache = database.scannerDao().findReplayCache("idem-1")

        assertThat(report.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.TERMINAL_ERROR)
        assertThat(report.itemOutcomes.single().reasonCode).isEqualTo("business_duplicate")
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(0)
        assertThat(replayCache?.reasonCode).isEqualTo("business_duplicate")
    }

    @Test
    fun plainDuplicateRemainsBroadInPersistenceWhileQueueRemovalStillFollowsTerminalRows() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-1", ticketCode = "VG-1", createdAt = 1_000L))

        api.uploadResponse =
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-1",
                                    status = "duplicate",
                                    message = "Already processed"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val replayCache = database.scannerDao().findReplayCache("idem-1")

        assertThat(report.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
        assertThat(report.itemOutcomes.single().reasonCode).isNull()
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(0)
        assertThat(replayCache?.reasonCode).isNull()
    }

    @Test
    fun flushRespectsConfiguredBatchSizeAndCurrentPayloadShape() = runTest {
        repeat(55) { index ->
            repository.queueScan(
                sampleScan(
                    idempotencyKey = "idem-$index",
                    ticketCode = "VG-$index",
                    createdAt = index.toLong() * 5_000L
                )
            )
        }

        api.uploadResponse =
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            (0 until 50).map { index ->
                                UploadedScanResult(
                                    idempotency_key = "idem-$index",
                                    status = "duplicate",
                                    message = "Already checked in",
                                    reason_code = if (index == 0) "business_duplicate" else null
                                )
                            },
                        processed = 50
                    ),
                error = null,
                message = null
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(api.lastUploadBody?.scans?.size).isEqualTo(50)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(5)
        assertThat(repository.latestFlushReport()?.itemOutcomes?.first()?.reasonCode)
            .isEqualTo("business_duplicate")
    }

    @Test
    fun marksServerErrorsRetryableAndPreservesQueue() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-server", createdAt = 10_000L))
        api.uploadException = httpException(500)

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.RETRYABLE_FAILURE)
        assertThat(report.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.RETRYABLE_FAILURE)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(1)
    }

    @Test
    fun marksNetworkErrorsRetryableAndPreservesQueue() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-network", createdAt = 10_000L))
        api.uploadException = IOException("offline")

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.RETRYABLE_FAILURE)
        assertThat(report.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.RETRYABLE_FAILURE)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(1)
    }

    @Test
    fun marksFlushAuthExpiredAndPreservesQueueWhenTokenMissing() = runTest {
        val noTokenRepository =
            CurrentPhoenixMobileScanRepository(
                scannerDao = database.scannerDao(),
                remoteDataSource = PhoenixMobileRemoteDataSource(api),
                sessionProvider = object : SessionProvider {
                    override suspend fun bearerToken(): String? = null
                },
                flushResultClassifier = FlushResultClassifier(),
                clock = clock
            )

        noTokenRepository.queueScan(sampleScan(idempotencyKey = "idem-auth", createdAt = 10_000L))

        val report = noTokenRepository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.AUTH_EXPIRED)
        assertThat(report.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.AUTH_EXPIRED)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(1)
    }

    @Test
    fun queueAdmissionDoesNotConsultReplayCacheReasonCodes() = runTest {
        database.scannerDao().upsertReplayCache(
            ReplayCacheEntity(
                idempotencyKey = "idem-old",
                status = "duplicate",
                message = "Already processed",
                reasonCode = "replay_duplicate",
                storedAt = "2026-03-12T09:00:00Z",
                terminal = true
            )
        )

        val result = repository.queueScan(sampleScan(idempotencyKey = "idem-new", createdAt = 10_000L))

        assertThat(result).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(1)
    }

    private fun sampleScan(
        idempotencyKey: String,
        ticketCode: String = "VG-001",
        createdAt: Long
    ): PendingScan =
        PendingScan(
            eventId = 5,
            ticketCode = ticketCode,
            idempotencyKey = idempotencyKey,
            createdAt = createdAt,
            scannedAt = "2026-03-12T10:00:00Z",
            direction = ScanDirection.IN,
            entranceName = "Main Gate",
            operatorName = "Scanner 1"
        )

    private fun httpException(statusCode: Int): HttpException {
        val response =
            Response.error<UploadScansResponse>(
                statusCode,
                ResponseBody.create(
                    "application/json".toMediaType(),
                    """{"error":"server_error"}"""
                )
            )

        return HttpException(response)
    }

    private class FakePhoenixMobileApi : PhoenixMobileApi {
        var lastUploadBody: UploadScansRequest? = null
        var uploadException: Exception? = null
        var uploadResponse: UploadScansResponse =
            UploadScansResponse(
                data = UploadScansPayload(results = emptyList(), processed = 0),
                error = null,
                message = null
            )

        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse {
            error("Not used in this test")
        }

        override suspend fun syncAttendees(since: String?): MobileSyncResponse {
            error("Not used in this test")
        }

        override suspend fun uploadScans(body: UploadScansRequest): UploadScansResponse {
            uploadException?.let { throw it }
            lastUploadBody = body
            return uploadResponse
        }
    }
}
