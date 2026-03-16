package za.co.voelgoed.fastcheck.di

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import javax.inject.Inject
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class HiltBindingsTest {
    @get:Rule
    var hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var sessionRepository: SessionRepository

    @Inject
    lateinit var syncRepository: SyncRepository

    @Inject
    lateinit var mobileScanRepository: MobileScanRepository

    @Inject
    lateinit var queueCapturedScanUseCase: QueueCapturedScanUseCase

    @Inject
    lateinit var flushQueuedScansUseCase: FlushQueuedScansUseCase

    @Inject
    lateinit var scanCapturePipeline: ScanCapturePipeline

    @Inject
    lateinit var scannerDao: ScannerDao

    @Before
    fun setUp() {
        hiltRule.inject()
    }

    @Test
    fun injectsTestReplacementsForRuntimeBoundaries() {
        assertThat(sessionRepository).isNotNull()
        assertThat(syncRepository).isNotNull()
        assertThat(mobileScanRepository).isNotNull()
        assertThat(queueCapturedScanUseCase).isNotNull()
        assertThat(flushQueuedScansUseCase).isNotNull()
        assertThat(scanCapturePipeline).isNotNull()
        assertThat(scannerDao).isNotNull()
    }
}
