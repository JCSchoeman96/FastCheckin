package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.test.runTest
import okhttp3.Headers
import okhttp3.Protocol
import okhttp3.Request
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansPayload
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import java.io.IOException
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineReason
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.domain.usecase.DefaultQueueCapturedScanUseCase
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import retrofit2.Response

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
                remoteDataSource = PhoenixMobileRemoteDataSource(api, clock),
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
    fun canonicalQueueingTreatsTrimmedScannerInputAsOneIdentityForReplaySuppressionAndUpload() = runTest {
        val queueUseCase =
            DefaultQueueCapturedScanUseCase(
                scanRepository = repository,
                sessionAuthGateway =
                    object : SessionAuthGateway {
                        override suspend fun currentEventId(): Long = 5L

                        override suspend fun currentOperatorName(): String? = "Scanner 1"
                    },
                clock = clock
            )

        val firstResult =
            queueUseCase.enqueue(
                ticketCode = "VG-001",
                direction = ScanDirection.IN,
                operatorName = "Manual",
                entranceName = "Main Gate"
            )
        val secondResult =
            queueUseCase.enqueue(
                ticketCode = " \tVG-001\r\n",
                direction = ScanDirection.IN,
                operatorName = "Manual",
                entranceName = "Main Gate"
            )

        api.uploadResponse =
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = database.scannerDao().loadQueuedScans().single().idempotencyKey,
                                    status = "success",
                                    message = "Check-in successful"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )
            )

        repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(firstResult).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(secondResult).isEqualTo(QueueCreationResult.ReplaySuppressed)
        assertThat(database.scannerDao().findReplaySuppression("VG-001")).isNotNull()
        assertThat(database.scannerDao().findReplaySuppression(" VG-001 ")).isNull()
        assertThat(api.lastUploadBody?.scans?.map { it.ticket_code }).containsExactly("VG-001")
    }

    @Test
    fun keepsUnmatchedQueueItemsForRetryAfterPartialSuccess() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-1", ticketCode = "VG-1", createdAt = 1_000L))
        repository.queueScan(sampleScan(idempotencyKey = "idem-2", ticketCode = "VG-2", createdAt = 5_000L))
        repository.queueScan(sampleScan(idempotencyKey = "idem-3", ticketCode = "VG-3", createdAt = 9_000L))

        api.uploadResponse =
            successResponse(
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
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            (0 until 50).map { index ->
                                UploadedScanResult(
                                    idempotency_key = "idem-$index",
                                    status = "duplicate",
                                    message = "Already checked in"
                                )
                            },
                        processed = 50
                    ),
                error = null,
                message = null
            )
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(api.lastUploadBody?.scans?.size).isEqualTo(50)
        assertThat(database.scannerDao().countPendingScans()).isEqualTo(5)
    }

    @Test
    fun marksFlushAuthExpiredAndPreservesQueueWhenTokenMissing() = runTest {
        val noTokenRepository =
            CurrentPhoenixMobileScanRepository(
                scannerDao = database.scannerDao(),
                remoteDataSource = PhoenixMobileRemoteDataSource(api, clock),
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
    fun flushSuccessMovesOverlayToConfirmedLocalUnsynced() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-success")
        api.uploadResponse =
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-overlay-success",
                                    status = "success",
                                    message = "Check-in successful"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )
            )

        repository.flushQueuedScans(maxBatchSize = 50)

        val overlay =
            database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-success")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name)
    }

    @Test
    fun flushDuplicateMovesOverlayToConflictDuplicate() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-dup")
        api.uploadResponse =
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-overlay-dup",
                                    status = "duplicate",
                                    message = "Already checked in"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )
            )

        repository.flushQueuedScans(maxBatchSize = 50)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-dup")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name)
    }

    @Test
    fun flushTerminalErrorMovesOverlayToConflictRejected() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-term")
        api.uploadResponse =
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-overlay-term",
                                    status = "error",
                                    message = "Payment invalid",
                                    reason_code = "payment_invalid"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )
            )

        repository.flushQueuedScans(maxBatchSize = 50)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-term")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.CONFLICT_REJECTED.name)
    }

    @Test
    fun flushTerminalErrorWithBusinessDuplicateMovesOverlayToConflictDuplicate() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-biz-dup")
        api.uploadResponse =
            successResponse(
            UploadScansResponse(
                data =
                    UploadScansPayload(
                        results =
                            listOf(
                                UploadedScanResult(
                                    idempotency_key = "idem-overlay-biz-dup",
                                    status = "error",
                                    message = "Duplicate",
                                    reason_code = "business_duplicate"
                                )
                            ),
                        processed = 1
                    ),
                error = null,
                message = null
            )
            )

        repository.flushQueuedScans(maxBatchSize = 50)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-biz-dup")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name)
    }

    @Test
    fun flushRetryableServerErrorDoesNotTransitionOverlay() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-retry")
        api.uploadResponse = errorResponse(500, """{"error":"server_error"}""")

        repository.flushQueuedScans(maxBatchSize = 50)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-retry")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.PENDING_LOCAL.name)
    }

    @Test
    fun flush400ClientErrorQuarantinesBatchAndDoesNotTouchReplayCacheOrOverlaySuccess() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-q-400")
        api.uploadResponse = errorResponse(400, """{"error":"bad_request"}""")

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(dao.countPendingScans()).isEqualTo(0)
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
        val q = dao.loadLatestQuarantinedScan()
        assertThat(q?.quarantineReason).isEqualTo(QuarantineReason.UNRECOVERABLE_API_CONTRACT_ERROR.wireValue)
        assertThat(q?.batchAttributed).isTrue()
        assertThat(dao.findReplayCache("idem-q-400")).isNull()
        val overlay = dao.findLocalAdmissionOverlayByIdempotencyKey("idem-q-400")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.PENDING_LOCAL.name)
    }

    @Test
    fun flushIncompleteResponseQuarantinesBatch() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-null-data", createdAt = 10_000L))
        api.uploadResponse =
            successResponse(
                UploadScansResponse(data = null, error = "missing", message = "no data")
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(dao.countPendingScans()).isEqualTo(0)
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
        assertThat(dao.loadLatestQuarantinedScan()?.quarantineReason)
            .isEqualTo(QuarantineReason.INCOMPLETE_SERVER_RESPONSE.wireValue)
    }

    /**
     * Critical truth: auth expiry must not quarantine — queue stays live for retry after re-login,
     * and quarantine count must remain zero (same contract as 5xx / IOException below).
     */
    @Test
    fun flush401PreservesQueueAndLeavesQuarantineEmpty() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-401", createdAt = 10_000L))
        api.uploadResponse = errorResponse(401, """{"error":"unauthorized"}""")

        repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(dao.countPendingScans()).isEqualTo(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(0)
        assertThat(repository.quarantineCount()).isEqualTo(0)
    }

    /**
     * Critical truth: retryable server errors must not move rows into quarantine — backlog remains
     * eligible for flush retries; quarantine count stays zero.
     */
    @Test
    fun flush5xxPreservesQueueAndLeavesQuarantineEmpty() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-500", createdAt = 10_000L))
        api.uploadResponse = errorResponse(503, """{"error":"unavailable"}""")

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(dao.countPendingScans()).isEqualTo(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(0)
        assertThat(repository.quarantineCount()).isEqualTo(0)
        assertThat(report.backpressureObserved).isTrue()
        assertThat(report.httpStatusCode).isEqualTo(503)
    }

    @Test
    fun flush429PreservesQueueAndLeavesQuarantineEmpty() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-429", createdAt = 10_000L))
        api.uploadResponse =
            errorResponse(
                429,
                """{"error":"rate_limited"}""",
                headers = Headers.headersOf("Retry-After", "5", "x-ratelimit-remaining", "0")
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.RETRYABLE_FAILURE)
        assertThat(report.retryAfterMillis).isEqualTo(5_000L)
        assertThat(report.httpStatusCode).isEqualTo(429)
        assertThat(report.rateLimitRemaining).isEqualTo(0)
        assertThat(report.backpressureObserved).isTrue()
        assertThat(dao.countPendingScans()).isEqualTo(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(0)
    }

    @Test
    fun flush429ParsesHttpDateRetryAfter() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-429-date", createdAt = 10_000L))
        val retryInstant = Instant.parse("2026-03-12T10:00:45Z")
        api.uploadResponse =
            errorResponse(
                429,
                """{"error":"rate_limited"}""",
                headers = Headers.headersOf("Retry-After", DateTimeFormatter.RFC_1123_DATE_TIME.format(retryInstant.atZone(ZoneOffset.UTC)))
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.retryAfterMillis).isEqualTo(45_000L)
    }

    @Test
    fun flushIgnoresInvalidRetryAfterAndFallsBackCleanly() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-429-invalid", createdAt = 10_000L))
        api.uploadResponse =
            errorResponse(
                429,
                """{"error":"rate_limited"}""",
                headers = Headers.headersOf("Retry-After", "Wed, 12 Mar 2026 09:59:59 GMT")
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.retryAfterMillis).isNull()
        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.RETRYABLE_FAILURE)
    }

    @Test
    fun flushSuccessSurfacesRateLimitHeadersWithoutChangingPayloadContract() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-success-headers", createdAt = 10_000L))
        api.uploadResponse =
            successResponse(
                UploadScansResponse(
                    data =
                        UploadScansPayload(
                            results =
                                listOf(
                                    UploadedScanResult(
                                        idempotency_key = "idem-success-headers",
                                        status = "success",
                                        message = "Check-in successful"
                                    )
                                ),
                            processed = 1
                        ),
                    error = null,
                    message = null
                ),
                headers =
                    Headers.headersOf(
                        "x-ratelimit-limit",
                        "50",
                        "x-ratelimit-remaining",
                        "49",
                        "x-ratelimit-reset",
                        "1741514400"
                    )
            )

        val report = repository.flushQueuedScans(maxBatchSize = 50)

        assertThat(report.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(report.rateLimitLimit).isEqualTo(50)
        assertThat(report.rateLimitRemaining).isEqualTo(49)
        assertThat(report.rateLimitResetEpochSeconds).isEqualTo(1_741_514_400L)
    }

    /**
     * Critical truth: transport failures must not quarantine — queue stays live for retry when
     * connectivity returns; quarantine count stays zero.
     */
    @Test
    fun flushIOExceptionPreservesQueueAndLeavesQuarantineEmpty() = runTest {
        repository.queueScan(sampleScan(idempotencyKey = "idem-io", createdAt = 10_000L))
        api.uploadIoException = IOException("network down")

        repository.flushQueuedScans(maxBatchSize = 50)
        val dao = database.scannerDao()

        assertThat(dao.countPendingScans()).isEqualTo(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(0)
        assertThat(repository.quarantineCount()).isEqualTo(0)
    }

    @Test
    fun flushAuthExpiredDoesNotTransitionOverlay() = runTest {
        seedQueueAndPendingOverlay(idempotencyKey = "idem-overlay-auth")
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

        noTokenRepository.flushQueuedScans(maxBatchSize = 50)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-overlay-auth")
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.PENDING_LOCAL.name)
    }

    private suspend fun seedQueueAndPendingOverlay(idempotencyKey: String) {
        val dao = database.scannerDao()
        dao.insertQueuedScan(
            QueuedScanEntity(
                eventId = 5,
                ticketCode = "VG-OVR",
                idempotencyKey = idempotencyKey,
                createdAt = 10_000L,
                scannedAt = "2026-03-12T10:00:00Z",
                entranceName = "Main Gate",
                operatorName = "Scanner 1"
            )
        )
        dao.upsertLocalAdmissionOverlay(
            LocalAdmissionOverlayEntity(
                eventId = 5,
                attendeeId = 1L,
                ticketCode = "VG-OVR",
                idempotencyKey = idempotencyKey,
                state = LocalAdmissionOverlayState.PENDING_LOCAL.name,
                createdAtEpochMillis = 10_000L,
                overlayScannedAt = "2026-03-12T10:00:00Z",
                expectedRemainingAfterOverlay = 0,
                operatorName = "Scanner 1",
                entranceName = "Main Gate"
            )
        )
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

    private class FakePhoenixMobileApi : PhoenixMobileApi {
        var lastUploadBody: UploadScansRequest? = null
        var uploadIoException: IOException? = null
        var uploadResponse: Response<UploadScansResponse> =
            Response.success(
                UploadScansResponse(
                    data = UploadScansPayload(results = emptyList(), processed = 0),
                    error = null,
                    message = null
                )
            )

        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse {
            error("Not used in this test")
        }

        override suspend fun syncAttendees(since: String?, cursor: String?, limit: Int): MobileSyncResponse {
            error("Not used in this test")
        }

        override suspend fun uploadScans(body: UploadScansRequest): Response<UploadScansResponse> {
            lastUploadBody = body
            uploadIoException?.let { throw it }
            return uploadResponse
        }
    }

    private fun successResponse(
        body: UploadScansResponse,
        headers: Headers = Headers.headersOf()
    ): Response<UploadScansResponse> = Response.success(body, headers)

    private fun errorResponse(
        code: Int,
        body: String,
        headers: Headers = Headers.headersOf()
    ): Response<UploadScansResponse> =
        Response.error(
            body.toResponseBody("application/json".toMediaType()),
            okhttp3.Response.Builder()
                .code(code)
                .message("HTTP $code")
                .protocol(Protocol.HTTP_1_1)
                .headers(headers)
                .request(Request.Builder().url("https://example.test/api/v1/mobile/scans").build())
                .build()
        )
}
