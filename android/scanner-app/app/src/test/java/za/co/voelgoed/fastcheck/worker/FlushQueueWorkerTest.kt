package za.co.voelgoed.fastcheck.worker

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.work.ListenableWorker
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import androidx.work.testing.TestListenableWorkerBuilder
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushBatchPolicy
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase

@RunWith(RobolectricTestRunner::class)
class FlushQueueWorkerTest {
    @Test
    fun returnsRetryOnlyForRetryableRepositoryFailures() = runTest {
        val recorder =
            RecordingFlushQueuedScansUseCase(
                FlushReport(
                    executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                    retryableRemainingCount = 3,
                    summaryMessage = "Retry later."
                )
            )
        val worker = buildWorker(recorder)

        val result = worker.doWork()

        assertThat(result).isInstanceOf(ListenableWorker.Result.Retry::class.java)
        assertThat(recorder.lastBatchSize).isEqualTo(AutoFlushBatchPolicy.DEFAULT_BATCH_SIZE)
    }

    @Test
    fun returnsFailureWhenAuthExpires() = runTest {
        val worker =
            buildWorker(
                RecordingFlushQueuedScansUseCase(
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "Login required."
                    )
                )
            )

        val result = worker.doWork()

        assertThat(result).isInstanceOf(ListenableWorker.Result.Failure::class.java)
    }

    @Test
    fun returnsSuccessWhenFlushClassificationCompletesWithTerminalNegatives() = runTest {
        val worker =
            buildWorker(
                RecordingFlushQueuedScansUseCase(
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already checked in"
                                )
                            ),
                        uploadedCount = 1,
                        summaryMessage = "Flush completed."
                    )
                )
            )

        val result = worker.doWork()

        assertThat(result).isInstanceOf(ListenableWorker.Result.Success::class.java)
    }

    private fun buildWorker(useCase: RecordingFlushQueuedScansUseCase): FlushQueueWorker {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val factory =
            object : WorkerFactory() {
                override fun createWorker(
                    appContext: Context,
                    workerClassName: String,
                    workerParameters: WorkerParameters
                ): ListenableWorker? =
                    if (workerClassName == FlushQueueWorker::class.java.name) {
                        FlushQueueWorker(
                            appContext = appContext,
                            workerParams = workerParameters,
                            flushQueuedScans = useCase
                        )
                    } else {
                        null
                    }
            }

        return TestListenableWorkerBuilder<FlushQueueWorker>(context)
            .setWorkerFactory(factory)
            .build()
    }

    private class RecordingFlushQueuedScansUseCase(
        private val report: FlushReport
    ) : FlushQueuedScansUseCase {
        var lastBatchSize: Int? = null

        override suspend fun run(maxBatchSize: Int): FlushReport {
            lastBatchSize = maxBatchSize
            return report
        }
    }
}
