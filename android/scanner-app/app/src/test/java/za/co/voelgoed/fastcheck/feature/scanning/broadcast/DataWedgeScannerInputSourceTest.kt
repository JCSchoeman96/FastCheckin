package za.co.voelgoed.fastcheck.feature.scanning.broadcast

import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class DataWedgeScannerInputSourceTest {
    private val appContext: Context = ApplicationProvider.getApplicationContext()
    private val clock: Clock = Clock.fixed(Instant.ofEpochMilli(1_700_000_000_000L), ZoneOffset.UTC)

    @Test
    fun broadcastPayloadTranslatesIntoCaptureEvent() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event }
            }

        source.start()
        appContext.sendBroadcast(
            Intent(DataWedgeScanContract.ACTION_SCAN)
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "  VG-DW-001  ")
        )

        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()
        val event = captures.single()

        assertThat(event.rawValue).isEqualTo("  VG-DW-001  ")
        assertThat(event.capturedAtEpochMillis).isEqualTo(1_700_000_000_000L)
        assertThat(event.sourceType).isEqualTo(ScannerSourceType.BROADCAST_INTENT)
        assertThat(event.sourceId).isEqualTo(DataWedgeScanContract.SOURCE_ID)

        collectJob.cancel()
        source.stop()
    }

    @Test
    fun blankPayloadIsIgnoredSafely() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<String>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event.rawValue }
            }

        source.start()
        appContext.sendBroadcast(
            Intent(DataWedgeScanContract.ACTION_SCAN)
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "   ")
        )

        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        assertThat(captures).isEmpty()

        collectJob.cancel()
        source.stop()
    }

    @Test
    fun unsupportedActionIsIgnoredSafely() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<String>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event.rawValue }
            }

        source.start()
        appContext.sendBroadcast(
            Intent("za.co.voelgoed.fastcheck.ACTION_UNSUPPORTED")
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "VG-DW-002")
        )

        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        assertThat(captures).isEmpty()

        collectJob.cancel()
        source.stop()
    }

    @Test
    fun startAndStopAreIdempotentAndStateTransitionsRemainCorrect() = runTest {
        val source = sourceUnderTest(testScheduler)
        assertThat(source.state.value).isEqualTo(ScannerSourceState.Idle)

        source.start()
        assertThat(source.state.value).isEqualTo(ScannerSourceState.Ready)
        source.start()
        assertThat(source.state.value).isEqualTo(ScannerSourceState.Ready)
        source.stop()
        assertThat(source.state.value).isEqualTo(ScannerSourceState.Idle)
        source.stop()
        assertThat(source.state.value).isEqualTo(ScannerSourceState.Idle)
    }

    @Test
    fun duplicateBroadcastsStillEmitDuplicateCaptureEvents() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<String>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event.rawValue }
            }

        source.start()
        repeat(2) {
            appContext.sendBroadcast(
                Intent(DataWedgeScanContract.ACTION_SCAN)
                    .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "VG-DW-DUPE")
            )
        }

        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        assertThat(captures).containsExactly("VG-DW-DUPE", "VG-DW-DUPE").inOrder()

        collectJob.cancel()
        source.stop()
    }

    @Test
    fun sourceCanRestartAndReceiveAgainAfterStop() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<String>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event.rawValue }
            }

        source.start()
        appContext.sendBroadcast(
            Intent(DataWedgeScanContract.ACTION_SCAN)
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "VG-DW-FIRST")
        )
        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        source.stop()
        source.start()
        appContext.sendBroadcast(
            Intent(DataWedgeScanContract.ACTION_SCAN)
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "VG-DW-SECOND")
        )
        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        assertThat(captures).containsExactly("VG-DW-FIRST", "VG-DW-SECOND").inOrder()

        collectJob.cancel()
        source.stop()
    }

    @Test
    fun noForwardingOccursAfterStop() = runTest {
        val source = sourceUnderTest(testScheduler)
        val captures = mutableListOf<String>()
        val collectJob =
            launch {
                source.captures.collect { event -> captures += event.rawValue }
            }

        source.start()
        source.stop()
        appContext.sendBroadcast(
            Intent(DataWedgeScanContract.ACTION_SCAN)
                .putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, "VG-DW-003")
        )

        shadowOf(Looper.getMainLooper()).idle()
        advanceUntilIdle()

        assertThat(captures).isEmpty()

        collectJob.cancel()
    }

    private fun sourceUnderTest(testScheduler: TestCoroutineScheduler) =
        DataWedgeScannerInputSource(
            appContext = appContext,
            appDispatchers =
                AppDispatchers(
                    io = StandardTestDispatcher(testScheduler),
                    default = StandardTestDispatcher(testScheduler),
                    main = StandardTestDispatcher(testScheduler)
                ),
            clock = clock
        )
}
