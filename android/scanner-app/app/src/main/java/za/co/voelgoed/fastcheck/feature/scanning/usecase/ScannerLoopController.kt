package za.co.voelgoed.fastcheck.feature.scanning.usecase

import kotlinx.coroutines.flow.SharedFlow

interface ScannerLoopController {
    val events: SharedFlow<ScannerLoopEvent>

    fun reset()

    fun onCooldownComplete()
}
