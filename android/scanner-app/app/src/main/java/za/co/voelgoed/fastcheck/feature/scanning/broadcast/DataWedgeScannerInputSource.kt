package za.co.voelgoed.fastcheck.feature.scanning.broadcast

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import java.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

class DataWedgeScannerInputSource(
    private val appContext: Context,
    private val appDispatchers: AppDispatchers,
    private val clock: Clock,
    override val id: String? = DataWedgeScanContract.SOURCE_ID
) : ScannerInputSource {

    override val type: ScannerSourceType = ScannerSourceType.BROADCAST_INTENT

    private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
    override val state: StateFlow<ScannerSourceState> = _state

    private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)
    override val captures = _captures.asSharedFlow()

    private val scope = CoroutineScope(SupervisorJob() + appDispatchers.default)

    private var receiver: BroadcastReceiver? = null

    override fun start() {
        if (receiver != null) {
            return
        }

        _state.value = ScannerSourceState.Starting

        val nextReceiver =
            object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    handleIntent(intent)
                }
            }

        try {
            ContextCompat.registerReceiver(
                appContext,
                nextReceiver,
                IntentFilter(DataWedgeScanContract.ACTION_SCAN),
                ContextCompat.RECEIVER_EXPORTED
            )
            receiver = nextReceiver
            _state.value = ScannerSourceState.Ready
        } catch (t: Throwable) {
            _state.value =
                ScannerSourceState.Error(t.message ?: "Failed to register DataWedge receiver")
            throw t
        }
    }

    override fun stop() {
        val activeReceiver = receiver ?: return

        _state.value = ScannerSourceState.Stopping
        try {
            appContext.unregisterReceiver(activeReceiver)
        } finally {
            receiver = null
            _state.value = ScannerSourceState.Idle
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != DataWedgeScanContract.ACTION_SCAN) {
            return
        }

        val rawValue =
            intent.getStringExtra(DataWedgeScanContract.EXTRA_DATA_STRING)
                ?.takeUnless { it.isBlank() }
                ?: return

        scope.launch {
            _captures.emit(
                ScannerCaptureEvent(
                    rawValue = rawValue,
                    capturedAtEpochMillis = clock.millis(),
                    sourceType = type,
                    sourceId = id
                )
            )
        }
    }
}
