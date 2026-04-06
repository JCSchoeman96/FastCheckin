package za.co.voelgoed.fastcheck.data.local

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.domain.model.QuarantineReason

@RunWith(RobolectricTestRunner::class)
class ScannerDaoQuarantineTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var dao: ScannerDao

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        dao = database.scannerDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun insertQuarantineAndCount() = runTest {
        dao.insertQuarantinedScans(listOf(sampleQuarantine("k1")))
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
        assertThat(dao.loadLatestQuarantinedScan()?.idempotencyKey).isEqualTo("k1")
    }

    @Test
    fun insertQuarantinedScansAndDeleteQueuedIsAtomic() = runTest {
        val qid =
            dao.insertQueuedScan(
                QueuedScanEntity(
                    eventId = 1L,
                    ticketCode = "T1",
                    idempotencyKey = "k-move",
                    createdAt = 1L,
                    scannedAt = "2026-01-01T00:00:00Z",
                    entranceName = "E",
                    operatorName = "O"
                )
            )
        assertThat(qid).isGreaterThan(0L)

        val row = dao.loadQueuedScans().single()
        dao.insertQuarantinedScansAndDeleteQueued(
            listOf(
                sampleQuarantine(
                    idempotencyKey = row.idempotencyKey,
                    originalQueueId = row.id
                )
            ),
            listOf(row.id)
        )

        assertThat(dao.loadQueuedScans()).isEmpty()
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
    }

    @Test
    fun observeQuarantineCountEmits() = runTest {
        assertThat(dao.observeQuarantinedScanCount().first()).isEqualTo(0)
        dao.insertQuarantinedScans(listOf(sampleQuarantine("obs")))
        assertThat(dao.observeQuarantinedScanCount().first()).isEqualTo(1)
    }

    private fun sampleQuarantine(
        idempotencyKey: String,
        originalQueueId: Long? = null
    ): QuarantinedScanEntity =
        QuarantinedScanEntity(
            originalQueueId = originalQueueId,
            eventId = 1L,
            ticketCode = "TC",
            idempotencyKey = idempotencyKey,
            createdAt = 1L,
            scannedAt = "2026-01-01T00:00:00Z",
            direction = "in",
            entranceName = "E",
            operatorName = "O",
            lastAttemptAt = null,
            quarantineReason = QuarantineReason.UNRECOVERABLE_API_CONTRACT_ERROR.wireValue,
            quarantineMessage = "msg",
            quarantinedAt = "2026-01-02T00:00:00Z",
            batchAttributed = false,
            overlayStateAtQuarantine = null
        )
}
