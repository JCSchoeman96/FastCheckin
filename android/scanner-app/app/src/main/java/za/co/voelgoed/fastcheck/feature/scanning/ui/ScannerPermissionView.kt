package za.co.voelgoed.fastcheck.feature.scanning.ui

import android.view.View
import za.co.voelgoed.fastcheck.databinding.ScannerPermissionViewBinding

class ScannerPermissionView(
    private val binding: ScannerPermissionViewBinding,
    private val onRequestPermission: () -> Unit
) {
    init {
        binding.requestCameraPermissionButton.setOnClickListener {
            onRequestPermission()
        }
    }

    fun render(state: ScannerPermissionUiState) {
        binding.scannerPermissionRoot.visibility =
            if (state.visible) {
                View.VISIBLE
            } else {
                View.GONE
            }
        binding.scannerPermissionTitle.text = state.headline
        binding.scannerPermissionMessage.text = state.message
        binding.requestCameraPermissionButton.text = state.requestButtonLabel
        binding.requestCameraPermissionButton.isEnabled = state.isRequestEnabled
    }
}
