package za.co.voelgoed.fastcheck.feature.scanning.camera

import java.time.Clock
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeFrameAnalyzer
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

/**
 * Camera-backed implementation of [ScannerInputSource].
 *
 * This class coordinates CameraX preview and ML Kit barcode analysis via [ScannerCameraBinder]
 * and [MlKitBarcodeFrameAnalyzer], emitting [ScannerCaptureEvent] instances while exposing a
 * lifecycle-aware [ScannerSourceState]. It does not perform any queueing or business-rule work.
 */
class CameraScannerInputSource(
    private val scannerCameraBinder: ScannerCameraBinder,
    private val lifecycleOwnerProvider: () -> androidx.lifecycle.LifecycleOwner,
    private val previewViewProvider: () -> androidx.camera.view.PreviewView,
    appDispatchers: AppDispatchers,
    clock: Clock,
    private val barcodeScannerEngine: za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine,
    override val id: String? = DEFAULT_CAMERA_ID
) : ScannerInputSource {

    override val type: ScannerSourceType = ScannerSourceType.CAMERA

    private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
    override val state: StateFlow<ScannerSourceState> = _state

    private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)
    override val captures = _captures.asSharedFlow()

    private val scope = CoroutineScope(SupervisorJob() + appDispatchers.default)
    private val sourceGeneration = AtomicLong(0)

    private val emitCapture: (ScannerCaptureEvent) -> Unit = { event ->
        scope.launch {
            _captures.emit(event)
        }
    }

    private val decodedHandler: DecodedBarcodeHandler =
        CameraDecodedBarcodeToSourceBridge(
            clock = clock,
            sourceId = id,
            emitCapture = emitCapture
        )

    private val analyzer: MlKitBarcodeFrameAnalyzer =
        MlKitBarcodeFrameAnalyzer(
            barcodeScannerEngine = barcodeScannerEngine,
            decodedBarcodeHandler = decodedHandler,
            appDispatchers = appDispatchers
        )

    override fun start() {
        val bindGeneration = sourceGeneration.incrementAndGet()
        _state.value = ScannerSourceState.Starting

        scannerCameraBinder.bind(
            lifecycleOwner = lifecycleOwnerProvider(),
            previewView = previewViewProvider(),
            analyzer = analyzer,
            onBound = {
                if (sourceGeneration.get() == bindGeneration) {
                    _state.value = ScannerSourceState.Ready
                }
            },
            onError = { throwable ->
                if (sourceGeneration.get() == bindGeneration) {
                    _state.value = ScannerSourceState.Error(throwable.message ?: "Failed to bind camera")
                }
            }
        )
    }

    override fun stop() {
        sourceGeneration.incrementAndGet()
        _state.value = ScannerSourceState.Stopping
        scannerCameraBinder.unbindAll()
        _state.value = ScannerSourceState.Idle
    }

    companion object {
        private const val DEFAULT_CAMERA_ID: String = "camera-default-0"
    }
}
