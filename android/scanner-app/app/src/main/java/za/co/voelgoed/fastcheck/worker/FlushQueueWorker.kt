package za.co.voelgoed.fastcheck.worker

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.hilt.work.HiltWorker
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushBatchPolicy
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase

@HiltWorker
class FlushQueueWorker @AssistedInject constructor(
    @Assisted appContext: Context,
    @Assisted workerParams: WorkerParameters,
    private val flushQueuedScans: FlushQueuedScansUseCase
) : CoroutineWorker(appContext, workerParams) {
    /**
     * Runtime contract: flush queued scans to POST /api/v1/mobile/scans using
     * { "scans": [...] } only. The worker owns retries; CameraX/ML Kit does not.
     */
    override suspend fun doWork(): Result =
        when (flushQueuedScans.run(maxBatchSize = AutoFlushBatchPolicy.DEFAULT_BATCH_SIZE).executionStatus) {
            FlushExecutionStatus.COMPLETED -> Result.success()
            FlushExecutionStatus.RETRYABLE_FAILURE -> Result.retry()
            FlushExecutionStatus.AUTH_EXPIRED -> Result.failure()
            FlushExecutionStatus.WORKER_FAILURE -> Result.failure()
        }
}
