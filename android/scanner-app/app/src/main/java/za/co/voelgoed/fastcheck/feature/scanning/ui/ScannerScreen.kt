package za.co.voelgoed.fastcheck.feature.scanning.ui

import android.view.View
import androidx.camera.core.ImageAnalysis
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.databinding.ScannerScreenBinding
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

class ScannerScreen(
    private val binding: ScannerScreenBinding,
    private val lifecycleOwner: LifecycleOwner,
    private val scanningViewModel: ScanningViewModel,
    private val scannerCameraBinder: ScannerCameraBinder,
    private val scannerAnalyzer: ImageAnalysis.Analyzer,
    private val onLaunchPermissionRequest: () -> Unit
) {
    private val permissionView =
        ScannerPermissionView(binding.scannerPermissionView) {
            scanningViewModel.onPermissionRequestStarted()
            onLaunchPermissionRequest()
        }

    private var previewBound = false
    private var previewBindingInProgress = false

    fun start() {
        lifecycleOwner.lifecycleScope.launch {
            lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                scanningViewModel.uiState.collectLatest { state ->
                    render(state)
                }
            }
        }

        scanningViewModel.start()
    }

    fun onPermissionResult(granted: Boolean) {
        if (!granted) {
            previewBound = false
            previewBindingInProgress = false
        }

        scanningViewModel.onPermissionResult(granted)
    }

    internal fun render(state: ScanningUiState) {
        permissionView.render(state.permissionUiState)
        binding.scannerPreview.visibility =
            if (state.isPreviewVisible) {
                View.VISIBLE
            } else {
                View.GONE
            }
        binding.scannerStatusValue.text = state.scannerStatus

        if (
            state.scannerState is ScannerState.InitializingCamera &&
            !previewBound &&
            !previewBindingInProgress
        ) {
            bindPreview()
        }
    }

    private fun bindPreview() {
        previewBindingInProgress = true
        scanningViewModel.onScannerBindingStarted()
        scannerCameraBinder.bind(
            lifecycleOwner = lifecycleOwner,
            previewView = binding.scannerPreview,
            analyzer = scannerAnalyzer,
            onBound = {
                previewBindingInProgress = false
                previewBound = true
                scanningViewModel.onScannerReady()
            },
            onError = { throwable ->
                previewBindingInProgress = false
                previewBound = false
                scanningViewModel.onScannerBindingFailed(throwable.message)
            }
        )
    }
}
